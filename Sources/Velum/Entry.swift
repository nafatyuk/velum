import AppKit
import SwiftUI

@main
struct VelumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        if CommandLine.arguments.contains("--dump") {
            DebugDump.run()
            exit(0)
        }
    }

    var body: some Scene {
        // The menu bar icon and its glass panel are owned by AppDelegate (see the note there).
        Settings { EmptyView() }
    }
}

/// `Velum --dump` prints what the panel would show, for checking from Terminal.
enum DebugDump {
    @MainActor
    static func run() {
        let collector = Collector()
        let first = collector.collect(force: true)
        let folders = Dictionary(first.accounts.map { ($0.config.key, $0.config.folder) }, uniquingKeysWith: { a, _ in a })
        let monitor = TransferMonitor()
        monitor.watch(folders)
        let tracker = UploadTracker()
        tracker.watch(folders)   // replays changes since the last run, if any
        RunLoop.main.run(until: Date().addingTimeInterval(2))   // let File Provider and FSEvents report
        let transfers = monitor.snapshot()
        let uploads = tracker.summary()
        let snapshot = collector.collect(force: true, transfers: transfers, uploads: uploads)

        print("OneDrive running: \(snapshot.oneDriveRunning) · Accessibility trusted: \(snapshot.axTrusted) · icon text readable: \(snapshot.liveItemsFound)")
        for account in snapshot.accounts {
            let t = transfers[account.config.key]
            print("• \(account.name) [\(account.config.key)] state=\(account.state) pid=\(account.pid.map(String.init) ?? "-") iconText=\(account.isLive) transfer=\(t.map { "up \($0.uploadingFiles) down \($0.downloadingFiles) other \($0.otherFiles), \($0.bytesText ?? "-")" } ?? "none")")
            if let u = uploads.accounts[account.config.key] {
                print("    uploads: \(u.uploading) uploading, \(u.waiting) waiting, \(u.failed.count) failed")
            }
            print("    \(account.headline)")
            if !account.detail.isEmpty { print("    \(account.detail)") }
            print("    folder: \(account.config.folder.path)")
            print("    online: \(account.config.webURL.absoluteString)")
        }
        print("Recent:")
        for item in snapshot.activity.prefix(10) {
            let verb = item.verb.padding(toLength: 10, withPad: " ", startingAt: 0)
            let when = RelTime.string(item.date).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("  \(verb) \(when) [\(item.accountKey)] \(item.name)")
        }
    }
}
