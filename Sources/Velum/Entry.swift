import AppKit
import SwiftUI

@main
struct VelumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        GoogleSignInDebug.runIfAsked()
        if CommandLine.arguments.contains("--dump") {
            DebugDump.run()
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-panel"), i + 1 < CommandLine.arguments.count {
            DebugDump.renderPanel(to: CommandLine.arguments[i + 1], dark: CommandLine.arguments.contains("--dark"))
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
        let (snapshot, transfers, uploads) = collectOnce()
        print(snapshot, transfers: transfers, uploads: uploads)
    }

    /// `Velum --render-panel <file.png> [--dark]` draws the panel, with live data, into an image, so a
    /// change can be looked at without replacing the running app. The glass is drawn as a plain window
    /// background: only the layout and text are real.
    @MainActor
    static func renderPanel(to path: String, dark: Bool) {
        var (snapshot, _, _) = collectOnce()
        // --many: three more copies of every account, to check the panel's height cap (--max-height N).
        if CommandLine.arguments.contains("--many") {
            snapshot.accounts += (2...4).flatMap { i in snapshot.accounts.map { $0.copy(suffix: i) } }
        }
        let store = AppModel.store
        if let i = CommandLine.arguments.firstIndex(of: "--max-height"), i + 1 < CommandLine.arguments.count,
           let h = Double(CommandLine.arguments[i + 1]) {
            store.maxPanelHeight = h
        }
        store.show(snapshot)
        store.loginItemEnabled = LoginItem.isEnabled
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = PanelView(store: store, actions: AppModel.actions)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Two passes: the panel measures its own parts and may switch to scrolling after the first.
        for _ in 0..<3 {
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        Swift.print("Rendered \(Int(host.bounds.width))×\(Int(host.bounds.height)) pt to \(path)")
    }

    @MainActor
    private static func collectOnce() -> (Snapshot, [String: TransferInfo], UploadsSnapshot) {
        let collector = Collector()
        let first = collector.collect(force: true)
        let roots = Dictionary(first.accounts.map { ($0.config.key, $0.config.watchRoots) }, uniquingKeysWith: { a, _ in a })
        let monitor = TransferMonitor()
        monitor.watch(roots)
        let tracker = UploadTracker()
        tracker.watch(roots, recordingUploadsFor: Set(first.accounts.filter { !$0.config.keepsOwnHistory }.map(\.id)))
        // iCloud's brctl check runs in the background and takes 10–13 s; wait for it so the dump is complete.
        for provider in collector.providers {
            (provider as? ICloudProvider)?.waitForFirstCheck(timeout: 30)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(2))   // let File Provider and FSEvents report
        let transfers = monitor.snapshot()
        let uploads = tracker.summary()
        let snapshot = collector.collect(force: true, transfers: transfers, uploads: uploads)
        return (snapshot, transfers, uploads)
    }

    @MainActor
    private static func print(_ snapshot: Snapshot, transfers: [String: TransferInfo], uploads: UploadsSnapshot) {
        for provider in snapshot.providers {
            switch provider.id {
            case .oneDrive:
                print("OneDrive running: \(snapshot.oneDriveRunning) · Accessibility trusted: \(snapshot.axTrusted) · icon text readable: \(snapshot.liveItemsFound)")
            case .iCloud:
                print("iCloud Drive: on\(provider.trouble.map { " · \($0)" } ?? "")")
            case .googleDrive:
                print("Google Drive running: \(provider.clientRunning == true)\(provider.trouble.map { " · \($0)" } ?? "")")
            }
        }
        for account in snapshot.accounts {
            let t = transfers[account.config.key]
            print("• \(account.name) [\(account.config.key)] state=\(account.state) pid=\(account.pid.map(String.init) ?? "-") iconText=\(account.isLive) transfer=\(t.map { "up \($0.uploadingFiles) down \($0.downloadingFiles) other \($0.otherFiles), \($0.bytesText ?? "-")" } ?? "none")")
            if let u = uploads.accounts[account.config.key] {
                print("    uploads: \(u.uploading) uploading, \(u.waiting) waiting, \(u.failed.count) failed")
            }
            print("    \(account.headline)")
            if !account.notes.isEmpty { print("    \(account.notes)") }
            if !account.detail.isEmpty { print("    \(account.detail)") }
            print("    folder: \(account.config.folder.path)")
            if account.config.watchRoots.count > 1 {
                print("    also watching: \(account.config.watchRoots.dropFirst().map(\.path).joined(separator: ", "))")
            }
            print("    online: \(account.config.webURL.absoluteString)")
        }
        print("Recent:")
        for item in snapshot.activity.prefix(10) {
            let verb = item.verb.padding(toLength: 10, withPad: " ", startingAt: 0)
            let when = RelTime.string(item.date).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("  \(verb) \(when) [\(item.accountKey)] \(item.name)")
        }
    }

    private static func print(_ line: String) { Swift.print(line) }
}

private extension AccountStatus {
    /// A renamed copy, for `--render-panel --many`.
    func copy(suffix: Int) -> AccountStatus {
        let c = config
        let config = AccountConfig(key: "\(c.key)-\(suffix)", provider: c.provider, folder: c.folder, watchRoots: c.watchRoots,
                                   places: c.places, fallbackName: c.fallbackName, webURL: c.webURL,
                                   recycleBinURL: c.recycleBinURL, storageURL: c.storageURL, keepsOwnHistory: c.keepsOwnHistory)
        var s = AccountStatus(config: config, name: "\(name) \(suffix)", state: state, headline: headline, detail: detail,
                              notes: notes, source: source, pid: pid, isLive: isLive, lastActivity: lastActivity)
        s.uploadsCovered = uploadsCovered
        return s
    }
}
