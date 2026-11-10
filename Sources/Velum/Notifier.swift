import Foundation
import UserNotifications

/// Notifies when something needs attention: uploads failing, a sync issue OneDrive reports, uploads stuck
/// for more than 10 minutes, or OneDrive stopping without the user quitting it from Velum. A problem has to
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
        case failed, issue, stuck, stopped

        var resolved: String {
            switch self {
            case .failed: "No files are failing to upload now."
            case .issue: "OneDrive no longer reports a sync problem."
            case .stuck: "The waiting uploads have gone through."
            case .stopped: "OneDrive is running again."
            }
        }
    }

    private struct Episode {
        let kind: Kind
        let firstSeen: Date
        var notified: Bool
    }

    private let center = UNUserNotificationCenter.current()
    private var episodes: [String: Episode] = [:]     // account key, or "onedrive" for OneDrive as a whole
    private let settle: TimeInterval = 30
    private let stuckAfter: TimeInterval = 10 * 60
    private let userStopGrace: TimeInterval = 120

    /// Set when the user quits or restarts OneDrive from Velum, so that isn't reported as a problem.
    var userStoppedOneDriveAt: Date?
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

    func update(_ snapshot: Snapshot, enabled: Bool, now: Date = Date()) {
        var current: [String: Problem] = [:]
        let userStopped = userStoppedOneDriveAt.map { now.timeIntervalSince($0) < userStopGrace } ?? false

        if !snapshot.oneDriveRunning {
            if !userStopped {
                current["onedrive"] = Problem(kind: .stopped, title: "OneDrive stopped",
                                              body: "Changes on this Mac aren’t syncing. Open Velum to start it again.")
            }
        } else {
            for account in snapshot.accounts {
                if account.uploadsFailed > 0 {
                    current[account.id] = Problem(kind: .failed,
                                                  title: "\(account.name): \(Self.files(account.uploadsFailed)) can’t upload",
                                                  body: account.firstFailure ?? "")
                } else if account.state == .error {
                    current[account.id] = Problem(kind: .issue, title: "\(account.name): \(account.headline)",
                                                  body: "OneDrive reports a sync problem.")
                } else if account.uploadsPending > 0, let since = account.oldestWaiting,
                          now.timeIntervalSince(since) > stuckAfter {
                    current[account.id] = Problem(kind: .stuck, title: "\(account.name): uploads are stuck",
                                                  body: "\(Self.files(account.uploadsPending)) waiting since \(RelTime.clock(since)).")
                } else if account.state == .notRunning, !userStopped {
                    current[account.id] = Problem(kind: .stopped, title: "\(account.name) isn’t syncing",
                                                  body: "OneDrive isn’t running for this account.")
                }
            }
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
            let name = key == "onedrive" ? "OneDrive" : (snapshot.accounts.first { $0.id == key }?.name ?? "OneDrive")
            post(key, title: "\(name): resolved", body: episode.kind.resolved, sound: false)
        }
    }

    private func post(_ key: String, title: String, body: String, sound: Bool) {
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
