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
    private let stuckAfter: TimeInterval = 10 * 60
    private let userStopGrace: TimeInterval = 120

    /// When the user last quit or restarted each service's app from Velum, so that isn't reported as a problem.
    var userStopped: [ProviderID: Date] = [:]
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
            } else if account.state == .error {
                current[account.id] = Problem(kind: .issue, title: "\(account.name): \(account.headline)",
                                              body: "\(account.provider.name) reports a sync problem.")
            } else if account.uploadsPending > 0, let since = account.oldestWaiting,
                      now.timeIntervalSince(since) > stuckAfter {
                current[account.id] = Problem(kind: .stuck, title: "\(account.name): uploads are stuck",
                                              body: "\(Self.files(account.uploadsPending)) waiting since \(RelTime.clock(since)).")
            } else if let since = account.workingSince, now.timeIntervalSince(since) > stuckAfter {
                current[account.id] = Problem(kind: .queued, title: "\(account.name): changes are stuck",
                                              body: "\(account.provider.name) has had changes queued since \(RelTime.clock(since)).")
            } else if account.state == .notRunning, !stoppedByUser(account.provider) {
                current[account.id] = Problem(kind: .stopped, title: "\(account.name) isn’t syncing",
                                              body: "\(account.provider.name) isn’t running for this account.")
            }
        }

        // Storage is separate from sync problems (its own key), so both can be true at once.
        for account in snapshot.accounts where account.storageFull {
            current["storage:\(account.id)"] = Problem(kind: .storage, title: "\(account.provider.name) storage full · \(account.name)",
                                                       body: "New files won’t upload until space is freed.")
        }

        for (key, problem) in current {
            if var episode = episodes[key], episode.kind == problem.kind {
                if !episode.notified, now.timeIntervalSince(episode.firstSeen) >= settle {
                    if enabled { post(key, title: problem.title, body: problem.body, sound: true) }
                    episode.notified = true   // also when disabled: switching on later shouldn't replay old news
                }
                episodes[key] = episode
            } else {
                episodes[key] = Episode(kind: problem.kind, firstSeen: now, notified: false)
            }
        }

        for (key, episode) in episodes where current[key] == nil {
            episodes[key] = nil
            guard episode.notified, enabled else { continue }
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

    private func post(_ key: String, title: String, body: String, sound: Bool) {
        debugLog("alert", "\(title) · \(body)\(systemAllowed ? "" : " (shown as Velum's banner)")")
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

    private static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

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
