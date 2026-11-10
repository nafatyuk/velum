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
        let monitor = TransferMonitor()
        monitor.watch(Dictionary(first.accounts.map { ($0.config.key, $0.config.folder) }, uniquingKeysWith: { a, _ in a }))
        RunLoop.main.run(until: Date().addingTimeInterval(2))   // let File Provider report current transfers
        let transfers = monitor.snapshot()
        let snapshot = collector.collect(force: true, transfers: transfers)

        print("OneDrive running: \(snapshot.oneDriveRunning) · Accessibility trusted: \(snapshot.axTrusted) · icon text readable: \(snapshot.liveItemsFound)")
        for account in snapshot.accounts {
            let t = transfers[account.config.key]
            print("• \(account.name) [\(account.config.key)] state=\(account.state) pid=\(account.pid.map(String.init) ?? "-") iconText=\(account.isLive) transfer=\(t.map { "\($0.headline), \($0.bytesText ?? "-")" } ?? "none")")
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
