import Foundation
import UserNotifications

/// Notifies when something needs attention: uploads failing, a sync issue a service reports, uploads stuck
/// for more than 10 minutes, or a sync app (OneDrive, Google Drive) stopping without the user quitting it from Velum. A problem has to
/// last 30 seconds before it notifies, it notifies once, and a notified problem gets one follow-up when it
/// clears. Clicking a notification opens Velum's panel.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private struct Problem {
        let kind: Kind
        let title: String
        let body: String
        /// What the debug log gets instead of `body` when the body names a file (file names never go to logs).
        var logged: String? = nil
    }

    private enum Kind {
        case failed, issue, stuck, stopped, queued, storage

        func resolved(service: String) -> String {
            switch self {
            case .failed: "No files are failing to upload now."
            case .issue: "\(service) no longer reports a sync problem."
            case .stuck: "The waiting uploads have gone through."
            case .queued: "\(service) has caught up."
            case .storage: "There’s room for new files again."
            case .stopped: "\(service) is running again."
            }
        }
    }

    private struct Episode {
        let kind: Kind
        let firstSeen: Date
        var notified: Bool
    }

    // Lazy: touching the notification center outside an app bundle (unit tests) crashes.
    private lazy var center = UNUserNotificationCenter.current()
    private var episodes: [String: Episode] = [:]     // account key, or the provider's id ("onedrive") for a whole service
    private let settle: TimeInterval = 30
    private var stuckAfter: TimeInterval { UploadTracker.stuckAfter }
    private let userStopGrace: TimeInterval = 120

    /// When the user last quit or restarted each service's app from Velum, so that isn't reported as a problem.
    var userStopped: [ProviderID: Date] = [:]
    /// One alert per client release that changed what Velum reads (card A7, Compatibility.swift).
    var compatibility = CompatibilityAlerts()
    /// What the sleep guard's note covers (card A5), set before each update: a stuck or queued alert it covers,
    /// and that alert's "resolved", wait while it does, so the user isn't told twice.
    var sleepGuard = SleepGuardCover()
    var onOpen: (() -> Void)?

    /// Whether macOS lets Velum post notifications. It only does for apps signed with an Apple-issued
    /// certificate, so a locally signed build falls back to Velum's own banner.
    private(set) var systemAllowed = false
    /// Shows Velum's own banner: (title, body, isProblem).
    var fallback: ((String, String, Bool) -> Void)?

    func start() {
        center.delegate = self
        center.getNotificationSettings { settings in
            let allowed = [.authorized, .provisional].contains(settings.authorizationStatus)
            Task { @MainActor in self.systemAllowed = allowed }
        }
    }

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.systemAllowed = granted }
        }
    }

    /// Accounts with uploads not yet in the cloud, as of the last update, so an account that disappears
    /// (signed out, disconnected) with work pending says so once instead of vanishing silently.
    private var unfinished: [String: (name: String, files: Int)] = [:]

    func update(_ snapshot: Snapshot, enabled: Bool, now: Date = Date()) {
        let present = Set(snapshot.accounts.map(\.id))
        for (key, last) in unfinished where !present.contains(key) && enabled {
            post(key, title: "\(last.name) was disconnected",
                 body: "\(Self.files(last.files)) hadn’t reached the cloud when it went away.", sound: true)
        }
        unfinished = Dictionary(uniqueKeysWithValues: snapshot.accounts.compactMap { account in
            let files = account.uploadsPending + account.uploadsFailed
            return files > 0 ? (account.id, (account.name, files)) : nil
        })

        var current: [String: Problem] = [:]
        func stoppedByUser(_ provider: ProviderID) -> Bool {
            userStopped[provider].map { now.timeIntervalSince($0) < userStopGrace } ?? false
        }

        let stopped = Set(snapshot.stoppedProviders)
        for provider in stopped where !stoppedByUser(provider) {
            current[provider.rawValue] = Problem(kind: .stopped, title: "\(provider.name) stopped",
                                                 body: "Changes on this Mac aren’t syncing. Open Velum to start it again.")
        }
        for account in snapshot.accounts where !stopped.contains(account.provider) {
            if account.uploadsFailed > 0 {
                current[account.id] = Problem(kind: .failed,
                                              title: "\(account.name): \(Self.files(account.uploadsFailed)) can’t upload",
                                              body: account.firstFailure ?? "")
            } else if account.state == .error, !account.isOld {
                current[account.id] = Problem(kind: .issue, title: "\(account.name): \(account.headline)",
                                              body: "\(account.provider.name) reports a sync problem.")
            } else if account.uploadsPending > 0, let since = account.oldestWaiting,
                      now.timeIntervalSince(since) > stuckAfter {
                let body = Self.stuckBody(account, stuck: snapshot.stuck, now: now)
                current[account.id] = Problem(kind: .stuck, title: "\(account.name): uploads are stuck",
                                              body: body.shown, logged: body.logged)
            } else if let since = account.workingSince, now.timeIntervalSince(since) > stuckAfter {
                current[account.id] = Problem(kind: .queued, title: "\(account.name): changes are stuck",
                                              body: "\(account.provider.name) has had changes queued since \(RelTime.clock(since)).")
            } else if account.state == .notRunning, !stoppedByUser(account.provider) {
                current[account.id] = Problem(kind: .stopped, title: "\(account.name) isn’t syncing",
                                              body: "\(account.provider.name) isn’t running for this account.")
            }
        }

        for alert in compatibility.due(snapshot.providers, now: now) where enabled {   // A7: once per release, no "resolved"
            post(alert.key, title: alert.title, body: alert.body, sound: true)
        }

        // Storage is separate from sync problems (its own key), so both can be true at once.
        for account in snapshot.accounts where account.storageFull {
            current["storage:\(account.id)"] = Problem(kind: .storage, title: "\(account.provider.name) storage full · \(account.name)",
                                                       body: "New files won’t upload until space is freed.")
        }

        for (key, problem) in current {
            if var episode = episodes[key], episode.kind == problem.kind {
                if !episode.notified, now.timeIntervalSince(episode.firstSeen) >= settle, !heldBySleepGuard(key, problem.kind, snapshot) {
                    if enabled { post(key, title: problem.title, body: problem.body, sound: true, logged: problem.logged) }
                    episode.notified = true   // also when disabled: switching on later shouldn't replay old news
                }
                episodes[key] = episode
            } else {
                episodes[key] = Episode(kind: problem.kind, firstSeen: now, notified: false)
            }
        }

        // An old problem report (A4) is neither news nor resolved: its episode waits for a fresh report.
        let held = Set(snapshot.accounts.filter { $0.isOld && $0.state == .error }.map(\.id))
        for (key, episode) in episodes where current[key] == nil && !held.contains(key) {
            episodes[key] = nil
            guard episode.notified, enabled, !heldBySleepGuard(key, episode.kind, nil) else { continue }
            // A service or account that was removed (uninstalled, signed out) isn't "resolved": it's gone.
            let accountKey = key.hasPrefix("storage:") ? String(key.dropFirst("storage:".count)) : key
            let stillThere = ProviderID(rawValue: key).map { id in snapshot.providers.contains { $0.id == id } }
                ?? snapshot.accounts.contains { $0.id == accountKey }
            guard stillThere else { continue }
            let account = snapshot.accounts.first { $0.id == accountKey }
            let service = ProviderID(rawValue: key)?.name ?? account?.provider.name ?? "OneDrive"
            let name = ProviderID(rawValue: key)?.name ?? account?.name ?? service
            post(key, title: "\(name): resolved", body: episode.kind.resolved(service: service), sound: false)
        }
    }

    private func post(_ key: String, title: String, body: String, sound: Bool, logged: String? = nil) {
        debugLog("alert", "\(title) · \(logged ?? body)\(systemAllowed ? "" : " (shown as Velum's banner)")")
        guard systemAllowed else {
            fallback?(title, body, sound)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        // One identifier per account, so a "resolved" note replaces the problem it answers.
        center.add(UNNotificationRequest(identifier: "velum.\(key)", content: content, trigger: nil))
    }

    /// The sleep guard's notes (card A5), through the same path as every alert. Key "sleep", so its follow-up
    /// replaces its problem note.
    func note(_ key: String, title: String, body: String, isProblem: Bool, logged: String) {
        post(key, title: title, body: body, sound: isProblem, logged: logged)
    }

    /// A queued alert waits while the guard follows that account's queue. A stuck alert waits while every file
    /// the account is stuck on is one the guard follows (`snapshot` nil: the "resolved" of one, while it follows
    /// files in that account).
    private func heldBySleepGuard(_ key: String, _ kind: Kind, _ snapshot: Snapshot?) -> Bool {
        switch kind {
        case .queued: return sleepGuard.queues.contains(key)
        case .stuck:
            guard sleepGuard.accounts.contains(key) else { return false }
            guard let snapshot else { return true }
            let stuck = snapshot.stuck.files.filter { $0.account == key }
            return stuck.count == (snapshot.stuck.perAccount[key] ?? 0) && stuck.allSatisfy { sleepGuard.files.contains($0.path) }
        default: return false
        }
    }

    private static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    /// The stuck alert's body, naming the account's oldest waiting file: "Report.docx and 2 more, waiting
    /// since 2:14 PM." Counts only files past the stuck threshold, not younger ones still on their way. With
    /// no listed file to name (the listing is capped), the count alone. `logged` never names a file.
    static func stuckBody(_ account: AccountStatus, stuck: PendingList, now: Date) -> (shown: String, logged: String) {
        let count = max(1, stuck.perAccount[account.id] ?? account.uploadsPending)
        let first = stuck.files.first { $0.account == account.id && $0.status == .waiting }
        let since = moment(first?.since ?? account.oldestWaiting ?? now, now: now)
        let logged = "\(files(count)) waiting since \(since)"
        guard let first else { return (logged + ".", logged) }
        let name = shortName(first.name)
        let shown = count > 1 ? "\(name) and \(count - 1) more, waiting since \(since)."
                              : "\(name) has been waiting since \(since)."
        return (shown, logged)
    }

    /// "2:14 PM" today, "Nov 9, 2:14 PM" before today: a bare time would be wrong on day three.
    static func moment(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? RelTime.clock(date)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// Long names lose their middle, keeping the start and the extension: 40 characters at most.
    static func shortName(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let head = limit / 2
        return name.prefix(head) + "…" + name.suffix(limit - head - 1)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.onOpen?() }
    }
}
