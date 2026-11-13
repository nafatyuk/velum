import AppKit
import SwiftUI

@main
struct VelumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        GoogleSignInDebug.runIfAsked()
        if CommandLine.arguments.contains("--dump"), CommandLine.arguments.contains("--redact") { DiagnosticsReport.printFromTerminal(); exit(0) }   // card S2
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
        // --sample <name>: a made-up panel (SampleData), safe to share; otherwise this Mac's live data.
        let sample = CommandLine.arguments.firstIndex(of: "--sample").flatMap { i in
            i + 1 < CommandLine.arguments.count ? SampleData.snapshot(CommandLine.arguments[i + 1]) : nil
        }
        var snapshot = sample ?? collectOnce().0
        // --many: three more copies of every account, to check the panel's height cap (--max-height N).
        if CommandLine.arguments.contains("--many") {
            snapshot.accounts += (2...4).flatMap { i in snapshot.accounts.map { $0.copy(suffix: i) } }
        }
        if CommandLine.arguments.contains("--sample-stuck") { snapshot.stuck = sampleStuck(snapshot.accounts) }
        let store = AppModel.store
        if let i = CommandLine.arguments.firstIndex(of: "--max-height"), i + 1 < CommandLine.arguments.count,
           let h = Double(CommandLine.arguments[i + 1]) {
            store.maxPanelHeight = h
        }
        store.show(snapshot)
        store.showingLegend = CommandLine.arguments.contains("--legend")
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
    static func collectOnce() -> (Snapshot, [String: TransferInfo], UploadsSnapshot) {
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
        var snapshot = collector.collect(force: true, transfers: transfers, uploads: uploads)
        snapshot.stuck = tracker.pending(olderThan: UploadTracker.stuckAfter)
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
            if let reason = account.reason { print("    why: \(reason)") }
            if !account.notes.isEmpty { print("    \(account.notes)") }
            if !account.detail.isEmpty { print("    \(account.detail)") }
            print("    folder: \(account.config.folder.path)")
            if account.config.watchRoots.count > 1 {
                print("    also watching: \(account.config.watchRoots.dropFirst().map(\.path).joined(separator: ", "))")
            }
            print("    online: \(account.config.webURL.absoluteString)")
        }
        printStuck(snapshot.stuck)
        // Card A7: every internal Velum reads, checked against the tested versions.
        print("Compatibility:")
        for line in snapshot.providers.compactMap(\.compatibility).flatMap(\.dumpLines) { print(line) }
        print("Recent:")
        for item in snapshot.activity.prefix(10) {
            let verb = item.verb.padding(toLength: 10, withPad: " ", startingAt: 0)
            let when = RelTime.string(item.date).padding(toLength: 11, withPad: " ", startingAt: 0)
            print("  \(verb) \(when) [\(item.accountKey)] \(item.name)")
        }
    }

    private static func print(_ line: String) { Swift.print(line) }

    /// The "Not in the cloud yet" list, as the panel would show it.
    @MainActor
    private static func printStuck(_ stuck: PendingList) {
        print("Not in the cloud yet: \(stuck.total) (failing, or waiting at least \(Int(UploadTracker.stuckAfter)) s)")
        for file in stuck.files {
            let state = switch file.status {
            case .waiting: "waiting"
            case .uploading: "uploading"
            case .failed(let reason): "failing: \(reason)"
            }
            print("  [\(file.account)] \(file.name) · changed \(RelTime.string(file.since)) · \(state)")
        }
    }

    /// Made-up files for `--render-panel --sample-stuck`, spread over the accounts shown, to look at the
    /// "Not in the cloud yet" section without real stuck files.
    private static func sampleStuck(_ accounts: [AccountStatus]) -> PendingList {
        guard !accounts.isEmpty else { return PendingList() }
        let now = Date()
        let samples: [(String, TimeInterval, PendingFile.Status)] = [
            ("Budget 2027.xlsx", 40 * 60, .failed("The file couldn’t be uploaded because it’s larger than the service allows.")),
            ("Invoice-1042.pdf", 3 * 86_400, .waiting),
            ("Lecture notes (week 9).pdf", 2 * 3_600 + 300, .waiting),
            ("Holiday photos.zip", 25 * 60, .uploading),
            ("Draft v3.pages", 14 * 60, .waiting),
            ("scan-0042.jpg", 12 * 60, .waiting),
            ("README.md", 11 * 60, .waiting),
        ]
        let files = samples.enumerated().map { i, sample in
            let account = accounts[i % accounts.count].config
            return PendingFile(account: account.key, path: account.folder.appending(path: "Documents/\(sample.0)").path,
                               since: now.addingTimeInterval(-sample.1), status: sample.2)
        }
        return PendingList(files: files, total: files.count,
                           perAccount: files.reduce(into: [:]) { $0[$1.account, default: 0] += 1 })
    }
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
