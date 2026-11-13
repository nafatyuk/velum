import Foundation
import SQLite3
import Testing
@testable import Velum

@Suite struct GoogleDrive {
    let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-someone.else@gmail.com")

    @Test func accountFromItsFolder() {
        let c = GoogleDriveProvider.config(email: "someone.else@gmail.com", root: root)
        #expect(c.key == "googledrive:someone.else@gmail.com")
        #expect(c.provider == .googleDrive)
        #expect(c.fallbackName == "someone.else@gmail.com")
        #expect(c.watchRoots == [root])
        #expect(c.keepsOwnHistory == false)
        #expect(c.webURL.absoluteString == "https://drive.google.com/drive/my-drive?authuser=someone.else@gmail.com")
        #expect(c.recycleBinURL?.absoluteString == "https://drive.google.com/drive/trash?authuser=someone.else@gmail.com")
        #expect(c.location(of: root.path + "/My Drive/Classes/a.pdf") == "In My Drive/Classes")
        #expect(c.location(of: root.path + "/Shared drives/Lab/b.pdf") == "In Shared drives/Lab")
    }

    @Test func queueDecidesTheReport() {
        let empty = GoogleDriveProvider.report(queued: 0, now: Fixture.now)
        #expect(empty.state == .ok)
        #expect(empty.source == "Google Drive's queue empty")
        let busy = GoogleDriveProvider.report(queued: 3, now: Fixture.now)
        #expect(busy.state == .syncing)
        #expect(busy.headline == "Syncing changes")
        let s = Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root), report: empty))
        #expect(s.headline == "Up to date")
        #expect(s.source == "Nothing pending · Google Drive's queue empty")
    }

    @Test func noQueueNoUpToDate() {
        let s = Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root)))
        #expect(s.state == .unknown)
        #expect(s.headline == "No status yet")
    }

    @Test func readsTheOperationsTable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-gd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "metadata_sqlite_db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE operations (id INTEGER PRIMARY KEY NOT NULL, proto BLOB); INSERT INTO operations (proto) VALUES (x'00'), (x'01');", nil, nil, nil)
        sqlite3_close(db)
        #expect(GoogleDriveProvider.countOperations(path) == 2)
        #expect(GoogleDriveProvider.countOperations(dir.appending(path: "missing").path) == nil)
    }

    @Test func dataFoldersMatchByTheirMyDriveLink() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "velum-gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let accountRoot = home.appending(path: "Library/CloudStorage/GoogleDrive-a@b.c")
        let driveFS = home.appending(path: "Library/Application Support/Google/DriveFS")
        for dir in [accountRoot.appending(path: "My Drive"), driveFS.appending(path: "123"), driveFS.appending(path: "456")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: driveFS.appending(path: "123/my-drive").path,
                                                   withDestinationPath: accountRoot.appending(path: "My Drive").path)
        let config = GoogleDriveProvider.config(email: "a@b.c", root: accountRoot)
        let found = GoogleDriveProvider.dataFolders(in: driveFS, for: [config])
        #expect(found[config.key]?.lastPathComponent == "123")
        #expect(found.count == 1)
    }

    @Test func plainFoldersAreNotAccounts() throws {
        // A leftover GoogleDrive-… folder that isn't a live File Provider domain must not appear.
        let home = FileManager.default.temporaryDirectory.appending(path: "velum-gd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Library/CloudStorage/GoogleDrive-gone@b.c/My Drive"),
                                                withIntermediateDirectories: true)
        #expect(GoogleDriveProvider(home: home).discover().isEmpty)
        #expect(GoogleDriveProvider(home: home).gather(force: true, now: Fixture.now).present == false)
    }
}

@MainActor
@Suite struct PlugAndPlay {
    @Test func nothingInstalledIsNotAnError() {
        let s = Snapshot()
        #expect(s.lidVerdict == .unknown("No cloud accounts found"))
        #expect(s.stoppedProviders.isEmpty)
    }

    @Test func aRemovedServiceIsNotResolved() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        let t0 = Fixture.now
        var stopped = Snapshot()
        stopped.providers = [ProviderStatus(id: .googleDrive, clientRunning: false), ProviderStatus(id: .iCloud)]
        notifier.update(stopped, enabled: true, now: t0)
        notifier.update(stopped, enabled: true, now: t0.addingTimeInterval(31))
        #expect(shown == ["Google Drive stopped"])
        var removed = Snapshot()                                   // Google Drive uninstalled: gone, not "running again"
        removed.providers = [ProviderStatus(id: .iCloud)]
        notifier.update(removed, enabled: true, now: t0.addingTimeInterval(60))
        #expect(shown == ["Google Drive stopped"])
    }

    @Test func absentProvidersShowNothing() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "velum-none-\(UUID().uuidString)")
        let collector = Collector(providers: [ICloudProvider(home: empty), GoogleDriveProvider(home: empty)])
        let snapshot = collector.collect(force: true)
        #expect(snapshot.providers.isEmpty)
        #expect(snapshot.accounts.isEmpty)
    }
}

@Suite struct GoogleDriveEvidence {
    let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c")

    @Test func busyQueueHoldsTheLid() {
        var e = Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root),
                                 report: GoogleDriveProvider.report(queued: 2, now: Fixture.now))
        e.workingSince = Fixture.now.addingTimeInterval(-60)
        let busy = Fixture.status(e)
        #expect(busy.headline == "Syncing changes")
        #expect(busy.workPending)
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .googleDrive, clientRunning: true)]
        s.accounts = [busy]
        #expect(s.lidVerdict == .busy("a@b.c"))
    }

    /// Card A7 (Fable): an unreadable queue is no longer "Up to date · Google Drive running": deletes and
    /// renames would go unseen. No report, so no status; the lid's side is in CompatibilityTests.
    @Test func unreadableQueueIsNoStatus() {
        let s = Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root)))
        #expect(s.state == .unknown)
        #expect(s.headline == "No status yet")
        #expect(!s.workPending)
    }

    @Test func shortcutTargetsAndTrash() {
        let c = GoogleDriveProvider.config(email: "a@b.c", root: root)
        #expect(c.location(of: root.path + "/.shortcut-targets-by-id/1AbCdEf/Lab notes/x.pdf") == "In a folder shared with you")
        #expect(!UploadTracker.isSyncable(root.path + "/.Trash/old.docx"))
    }
}

@MainActor
@Suite struct LifecycleAlerts {
    func account(_ email: String, pending: Int = 0, workingSince: Date? = nil) -> AccountStatus {
        let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-\(email)")
        var uploads = UploadSummary()
        uploads.waiting = pending
        var e = Fixture.evidence(GoogleDriveProvider.config(email: email, root: root),
                                 report: GoogleDriveProvider.report(queued: workingSince == nil ? 0 : 1, now: Fixture.now))
        e.workingSince = workingSince
        return Fixture.status(e, uploads: uploads)
    }

    func snapshot(_ accounts: [AccountStatus]) -> Snapshot {
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .googleDrive, clientRunning: true)]
        s.accounts = accounts
        return s
    }

    @Test func disconnectingWithPendingUploadsSaysSoOnce() {
        let notifier = Notifier()
        var shown: [(String, String)] = []
        notifier.fallback = { title, body, _ in shown.append((title, body)) }
        notifier.update(snapshot([account("a@b.c", pending: 3), account("x@y.z")]), enabled: true, now: Fixture.now)
        notifier.update(snapshot([account("x@y.z")]), enabled: true, now: Fixture.now.addingTimeInterval(5))
        notifier.update(snapshot([account("x@y.z")]), enabled: true, now: Fixture.now.addingTimeInterval(10))
        #expect(shown.map(\.0) == ["a@b.c was disconnected"])
        #expect(shown.first?.1 == "3 files hadn’t reached the cloud when it went away.")
    }

    @Test func disconnectingCleanIsQuiet() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        notifier.update(snapshot([account("a@b.c"), account("x@y.z")]), enabled: true, now: Fixture.now)
        notifier.update(snapshot([account("x@y.z")]), enabled: true, now: Fixture.now.addingTimeInterval(5))
        #expect(shown.isEmpty)
    }

    @Test func aQueueStuckForTenMinutesAlerts() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        let since = Fixture.now.addingTimeInterval(-11 * 60)
        notifier.update(snapshot([account("a@b.c", workingSince: since)]), enabled: true, now: Fixture.now)
        notifier.update(snapshot([account("a@b.c", workingSince: since)]), enabled: true, now: Fixture.now.addingTimeInterval(31))
        #expect(shown == ["a@b.c: changes are stuck"])
    }

    @Test func aStoppedClientDoesNotHideAFailingUpload() {
        let store = Store()
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .oneDrive, clientRunning: false), ProviderStatus(id: .googleDrive, clientRunning: true)]
        var uploads = UploadSummary()
        uploads.failed = ["a.txt: nope"]
        let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c")
        s.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), running: false)),
                      Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root)), uploads: uploads)]
        store.show(s)
        #expect(store.overallState == .error)
        #expect(store.title == "Cloud Sync")
    }

    @Test func manyAccountsSummariseInsteadOfListing() {
        let store = Store()
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .googleDrive, clientRunning: true)]
        s.accounts = (1...8).map { account("user\($0)@b.c", pending: $0 == 3 ? 2 : 0) }
        store.show(s)
        #expect(store.compactRows)
        #expect(store.tooltip == "user3@b.c: Waiting to upload 2 files\n7 accounts up to date")
    }
}
