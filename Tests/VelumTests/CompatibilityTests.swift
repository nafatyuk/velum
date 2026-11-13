import Foundation
import SQLite3
import Testing
@testable import Velum

/// Card A7. Every fixture is made up inside a temporary folder: never a real OneDrive, Google Drive or iCloud file.
enum CompatFixture {
    static func home() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "velum-a7-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    static func sqlite(_ path: URL, _ sql: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(path.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }

    static let historyTable = """
        CREATE TABLE history_list (FilePath TEXT NOT NULL, FileName TEXT NOT NULL, HydratingProcess TEXT, HydratingExe TEXT,
        ItemType INTEGER NOT NULL, LastUpdatedTimeUTC TIMESTAMP NOT NULL, PRIMARY KEY(FilePath));
        """

    static func oneDriveHistory(_ home: URL, key: String = "Personal", sql: String = historyTable) throws {
        try sqlite(home.appending(path: "Library/Application Support/OneDrive/settings/\(key)/UXDatabase.db"), sql)
    }

    static func oneDriveLog(_ home: URL, key: String = "Personal", _ text: String) throws {
        let dir = home.appending(path: "Library/Logs/OneDrive/\(key)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appending(path: "SyncDiagnostics.log"), atomically: true, encoding: .utf8)
    }

    static func oneDrive(_ home: URL, version: String = "26.212.1029") -> OneDriveCompatibility {
        let compat = OneDriveCompatibility(home: home)
        compat.readVersion = { version }
        compat.isLive = { _ in true }
        return compat
    }

    static func evidence(_ configs: [AccountConfig], running: Bool = true, activity: [Activity] = []) -> ProviderEvidence {
        var e = ProviderEvidence(present: true, clientRunning: running)
        e.accounts = configs.map { AccountEvidence(config: $0, name: $0.fallbackName) }
        e.activity = activity
        return e
    }

    static func activity(_ name: String, key: String = "Personal", kind: Int = 5, date: Date = Fixture.now) -> Activity {
        Activity(accountKey: key, path: "/Users/test/OneDrive/\(name)", name: name, kind: kind, date: date, app: nil)
    }

    static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "velum-a7-\(UUID().uuidString)")!
    }

    static func provider(_ id: ProviderID, _ report: CompatibilityReport) -> ProviderStatus {
        var p = ProviderStatus(id: id, clientRunning: id == .iCloud ? nil : true)
        p.compatibility = report
        return p
    }
}

@Suite struct TestedVersions {
    @Test func buildsMatchTheirRelease() {
        #expect(ProviderID.oneDrive.isTested("26.204.1019"))
        #expect(ProviderID.oneDrive.isTested("26.212.1029"))
        #expect(!ProviderID.oneDrive.isTested("26.220.1004"))
        #expect(!ProviderID.oneDrive.isTested("26.2"))
        #expect(ProviderID.googleDrive.isTested("133.0"))
        #expect(!ProviderID.googleDrive.isTested("134.0"))
        #expect(!ProviderID.googleDrive.isTested("1330.0"))
        #expect(ProviderID.iCloud.isTested("27.3"))
        #expect(ProviderID.iCloud.isTested("27.3.1"))
        #expect(!ProviderID.iCloud.isTested("28.0"))
    }

    @Test func clientNames() {
        #expect(CompatibilityReport(provider: .oneDrive, version: "27.0.1001").client == "OneDrive 27.0")
        #expect(CompatibilityReport(provider: .googleDrive, version: "134.0").client == "Google Drive 134")
        #expect(CompatibilityReport(provider: .iCloud, version: "28.0").client == "macOS 28.0")
        #expect(CompatibilityReport(provider: .oneDrive, version: nil).client == "OneDrive")
    }

    @Test func readsTheVersionFromTheAppsInfoPlist() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appending(path: "Some.app")
        try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "26.220.1004"], format: .xml, options: 0)
        try plist.write(to: app.appending(path: "Contents/Info.plist"))
        #expect(ClientVersion.version(ofAppAt: app) == "26.220.1004")
        #expect(ClientVersion.version(ofAppAt: home.appending(path: "Missing.app")) == nil)
    }
}

@Suite struct SchemaReads {
    @Test func tellsAChangedShapeFromAHiccup() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let db = home.appending(path: "a.db")
        try CompatFixture.sqlite(db, "CREATE TABLE operations (id INTEGER PRIMARY KEY NOT NULL, proto BLOB);")
        #expect(SQLiteSchema.columns(of: "operations", in: db.path) == .columns(["id", "proto"]))
        #expect(SQLiteSchema.columns(of: "missing", in: db.path) == .noTable)
        #expect(SQLiteSchema.columns(of: "operations", in: home.appending(path: "none.db").path) == .noFile)
        let text = home.appending(path: "text.db")
        try String(repeating: "not a database ", count: 100).write(to: text, atomically: true, encoding: .utf8)
        #expect(SQLiteSchema.columns(of: "operations", in: text.path) == .notADatabase)
        #expect(SQLiteSchema.check(.busy, table: "t", required: []) == nil)
        #expect(SQLiteSchema.check(.columns(["a"]), table: "t", required: ["a", "b"])?.0 == .changed)
    }
}

@Suite struct OneDriveChecks {
    let personal = Fixture.oneDrive()

    /// Fixture: an SQLite file with a renamed column.
    @Test func aRenamedColumnHidesTheActivityList() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home, sql: CompatFixture.historyTable.replacingOccurrences(of: "FileName TEXT", with: "ItemName TEXT"))
        try CompatFixture.oneDriveLog(home, "SyncProgressState: 16777216\n")
        let compat = CompatFixture.oneDrive(home, version: "27.0.1001")
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal], activity: [CompatFixture.activity("a.txt")])
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)

        #expect(e.activity.isEmpty)
        #expect(e.accounts[0].lastActivity == nil)
        #expect(e.accounts[0].compatibilityNote == "Can’t read OneDrive 27.0’s activity list · not shown in Recent")
        #expect(e.accounts[0].notes.first == e.accounts[0].compatibilityNote)
        let report = try #require(e.compatibility)
        #expect(report.alerting.map(\.name) == ["activity list (UXDatabase.db)"])
        #expect(report.lidReason == nil)       // the lid never relied on the activity list
        #expect(CompatibilityText.alertBody(report) == "Velum isn’t using OneDrive’s activity list for now. Open Cloud Sync to see what’s affected.")
    }

    /// Fixture: a log with an unknown code. The row is unknown and says why; a new value alone doesn't alert.
    @Test func anUnknownCodeIsUnknownNeverHealthy() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        try CompatFixture.oneDriveLog(home, "SyncProgressState: 4096\npid = 123\n")
        let compat = CompatFixture.oneDrive(home)
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal])
        e.accounts[0].report = OneDriveProvider.report(from: OneDriveFiles.diagnostics(at: home.appending(path: "Library/Logs/OneDrive/Personal/SyncDiagnostics.log").path))
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)

        let status = Fixture.status(e.accounts[0])
        #expect(status.state == .unknown)
        #expect(status.headline == "Status unknown")
        #expect(status.compatibilityNote == "OneDrive reported a status Velum doesn’t know · uploads are still tracked")
        let report = try #require(e.compatibility)
        #expect(report.counted.first?.detail == "unknown code 4096")
        #expect(report.alerting.isEmpty)
        #expect(CompatibilityReport.line(report.counted[0]) == "??  status report (SyncDiagnostics.log) · Personal: unknown code 4096 (recorded, no alert)")
    }

    @Test func aReportWithoutItsCodeLineIsDropped() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        try CompatFixture.oneDriveLog(home, "SyncState = Healthy\nFilesToUpload = 0\n")
        let compat = CompatFixture.oneDrive(home, version: "27.0.1001")
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal])
        e.accounts[0].report = OneDriveProvider.report(from: OneDriveFiles.diagnostics(at: home.appending(path: "Library/Logs/OneDrive/Personal/SyncDiagnostics.log").path))
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)

        let status = Fixture.status(e.accounts[0])
        #expect(status.state == .unknown)
        #expect(status.headline == "No status yet")
        #expect(status.compatibilityNote == "Can’t read OneDrive 27.0’s status report · uploads are still tracked")
        #expect(e.compatibility?.alerting.map(\.detail) == ["no SyncProgressState line"])
    }

    @Test func noReportYetIsNotAChange() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        let compat = CompatFixture.oneDrive(home)
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal])
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)
        #expect(e.compatibility?.counted.isEmpty == true)
        #expect(e.accounts[0].compatibilityNote == nil)
    }

    /// Fixture: a missing .ini. OneDrive's live folder still shows, as an account Velum can only watch.
    @Test func settingsThatListNoAccountFallBackToTheFolder() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        try fm.createDirectory(at: home.appending(path: "Library/Application Support/OneDrive/settings/Personal"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appending(path: "Library/CloudStorage/OneDrive-Personal"), withIntermediateDirectories: true)
        let compat = CompatFixture.oneDrive(home, version: "27.0.1001")

        let configs = compat.discovered([], now: Fixture.now)
        #expect(configs.map(\.key) == ["onedrive-folder:OneDrive-Personal"])
        #expect(configs.first?.fallbackName == "Personal")
        #expect(configs.first?.keepsOwnHistory == false)
        var e = CompatFixture.evidence(configs)
        e.accounts[0].running = false        // no process can be matched without settings
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)

        #expect(e.accounts[0].running)
        let status = Fixture.status(e.accounts[0])
        #expect(status.state == .unknown)
        #expect(status.compatibilityNote == "Found from its folder · Velum can’t read OneDrive 27.0’s settings")
        let report = try #require(e.compatibility)
        #expect(report.alerting.map(\.phrase) == ["settings"])
        #expect(report.lidReason == nil)      // every live folder has a row, so the lid still covers it

        // The lid rests on per-file flags, and every live folder has a row: nothing it relied on was dropped.
        var snapshot = Snapshot()
        snapshot.providers = [CompatFixture.provider(.oneDrive, report)]
        snapshot.accounts = [status]
        #expect(snapshot.lidVerdict == .safe)
    }

    @Test func signedOutOrAppStoreOneDriveIsNotAChange() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appending(path: "Library/CloudStorage/OneDrive-Personal"), withIntermediateDirectories: true)
        // No settings folder (OneDrive from the App Store keeps its own elsewhere): nothing, no fallback, no alert.
        let compat = CompatFixture.oneDrive(home)
        #expect(compat.discovered([], now: Fixture.now).isEmpty)
        // No live folder (signed out of everything): nothing either.
        try FileManager.default.createDirectory(at: home.appending(path: "Library/Application Support/OneDrive/settings/Personal"), withIntermediateDirectories: true)
        compat.isLive = { _ in false }
        #expect(compat.discovered([], now: Fixture.now).isEmpty)
        // Not installed at all.
        compat.isLive = { _ in true }
        compat.readVersion = { nil }
        #expect(compat.discovered([], now: Fixture.now).isEmpty)
    }

    /// Fixture: a newer version string. Every check passes, so nothing degrades and nothing alerts.
    @Test func aNewerVersionAloneChangesNothing() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        try CompatFixture.oneDriveLog(home, "SyncProgressState: 16777216\n")
        let compat = CompatFixture.oneDrive(home, version: "26.212.1029")
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal])
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)
        let before = try #require(e.compatibility)
        #expect(before.isTested)

        compat.readVersion = { "26.220.1004" }
        _ = compat.discovered([personal], now: Fixture.now.addingTimeInterval(60))
        var after = CompatFixture.evidence([personal])
        compat.apply(&after, mappingUnknown: false, now: Fixture.now.addingTimeInterval(60))
        let report = try #require(after.compatibility)
        #expect(!report.isTested)
        #expect(report.counted.isEmpty)
        #expect(report.headline == "OneDrive 26.220 (26.220.1004) · not tested (tested: 26.204, 26.212) · every check that could run passes")
        #expect(report.changes(from: before).first == "OneDrive updated from 26.212.1029: OneDrive 26.220 (26.220.1004) · not tested (tested: 26.204, 26.212) · every check that could run passes")
        #expect(after.accounts[0].compatibilityNote == nil)
        let alerts = CompatibilityAlerts(defaults: CompatFixture.defaults())
        #expect(alerts.due([CompatFixture.provider(.oneDrive, report)], now: Fixture.now).isEmpty)
        #expect(alerts.due([CompatFixture.provider(.oneDrive, report)], now: Fixture.now.addingTimeInterval(120)).isEmpty)
    }

    @Test func unknownEntriesLeaveRecentQuietly_badTimesDont() {
        let rows = [CompatFixture.activity("a.txt", kind: 5), CompatFixture.activity("b.txt", kind: 13),
                    CompatFixture.activity("c.txt", kind: 4, date: Fixture.now.addingTimeInterval(-3600))]
        let screened = OneDriveCompatibility.screen(rows, now: Fixture.now)
        #expect(screened.kept.map(\.name) == ["a.txt", "c.txt"])
        #expect(screened.check?.result == .unrecognized)
        #expect(screened.check?.alerts == false)

        // Milliseconds read as seconds land tens of thousands of years out: the list changed shape.
        let future = [CompatFixture.activity("d.txt", date: Date(timeIntervalSince1970: 1_794_000_000_000))]
        let bad = OneDriveCompatibility.screen(future, now: Fixture.now)
        #expect(bad.kept.isEmpty)
        #expect(bad.check?.result == .changed)
        #expect(OneDriveCompatibility.screen([], now: Fixture.now).check == nil)
    }

    @Test func unmatchedProcessesGetANoteAfterTheirGrace_notTheLid() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        let compat = CompatFixture.oneDrive(home)
        _ = compat.discovered([personal], now: Fixture.now)
        var early = CompatFixture.evidence([personal])
        compat.apply(&early, mappingUnknown: true, now: Fixture.now)
        #expect(early.accounts[0].compatibilityNote == nil)

        var late = CompatFixture.evidence([personal])
        compat.apply(&late, mappingUnknown: true, now: Fixture.now.addingTimeInterval(121))
        #expect(late.accounts[0].compatibilityNote == "Can’t tell whether OneDrive is running for this account")
        #expect(late.compatibility?.lidReason == nil)
        #expect(late.compatibility?.alerting.isEmpty == true)
    }

    @Test func aLiveFolderNoRowWatchesStopsTheLidAfterAMinute() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        for name in ["OneDrive-Personal", "OneDrive-SharedLibraries-Contoso"] {
            try FileManager.default.createDirectory(at: home.appending(path: "Library/CloudStorage/\(name)"), withIntermediateDirectories: true)
        }
        let folder = home.appending(path: "Library/CloudStorage/OneDrive-Personal")
        let config = AccountConfig(key: "Personal", provider: .oneDrive, folder: folder, watchRoots: [folder], places: [],
                                   fallbackName: "Personal", webURL: URL(string: "https://onedrive.live.com/")!)
        let compat = CompatFixture.oneDrive(home)
        _ = compat.discovered([config], now: Fixture.now)
        var first = CompatFixture.evidence([config])
        compat.apply(&first, mappingUnknown: false, now: Fixture.now)
        #expect(first.compatibility?.lidReason == nil)

        var later = CompatFixture.evidence([config])
        compat.apply(&later, mappingUnknown: false, now: Fixture.now.addingTimeInterval(61))
        let report = try #require(later.compatibility)
        #expect(report.lidReason == "Velum isn’t watching every OneDrive folder")
        #expect(report.alerting.isEmpty)
        #expect(report.counted.first?.detail == "live folder not watched: OneDrive-SharedLibraries-Contoso")

        var snapshot = Snapshot()
        snapshot.providers = [CompatFixture.provider(.oneDrive, report)]
        snapshot.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date")))]
        #expect(snapshot.lidVerdict == .unknown("Velum isn’t watching every OneDrive folder"))
    }
}

@Suite struct GoogleDriveChecks {
    func setUp(_ home: URL, folder: String = "GoogleDrive-a@b.c", queueSQL: String = "CREATE TABLE operations (id INTEGER PRIMARY KEY NOT NULL, proto BLOB);") throws
        -> (compat: GoogleDriveCompatibility, root: URL, driveFS: URL) {
        let cloud = home.appending(path: "Library/CloudStorage")
        let driveFS = home.appending(path: "Library/Application Support/Google/DriveFS")
        let root = cloud.appending(path: folder)
        try FileManager.default.createDirectory(at: root.appending(path: "My Drive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveFS.appending(path: "123"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: driveFS.appending(path: "123/my-drive").path,
                                                   withDestinationPath: root.appending(path: "My Drive").path)
        try CompatFixture.sqlite(driveFS.appending(path: "123/metadata_sqlite_db"),
                                 queueSQL + " CREATE TABLE properties (property TEXT PRIMARY KEY NOT NULL, value BLOB);")
        let compat = GoogleDriveCompatibility(cloudStorage: cloud, driveFS: driveFS)
        compat.readVersion = { "134.0" }
        compat.isLive = { _ in true }
        return (compat, root, driveFS)
    }

    @Test func aFailedQueueReadLeansOnTheLastGoodOneFor10Seconds() {
        let compat = GoogleDriveCompatibility(cloudStorage: URL(fileURLWithPath: "/nowhere"), driveFS: URL(fileURLWithPath: "/nowhere"))
        #expect(compat.queue("k", read: 3, now: Fixture.now) == 3)
        #expect(compat.queue("k", read: nil, now: Fixture.now.addingTimeInterval(5)) == 3)
        #expect(compat.queue("k", read: nil, now: Fixture.now.addingTimeInterval(11)) == nil)
        #expect(compat.queue("other", read: nil, now: Fixture.now) == nil)
    }

    @Test func anUnreadableQueueMeansNoStatusAndNoSafeLid() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let (compat, root, driveFS) = try setUp(home)
        let config = GoogleDriveProvider.config(email: "a@b.c", root: root)
        let found = compat.discovered([config], dataFolders: GoogleDriveProvider.dataFolders(in: driveFS, for: [config]), now: Fixture.now)
        #expect(found.dataFolders[config.key] != nil)
        _ = compat.queue(config.key, read: nil, now: Fixture.now)
        var e = CompatFixture.evidence([config])     // no report: the queue couldn't be read
        compat.apply(&e, now: Fixture.now)

        let status = Fixture.status(e.accounts[0])
        #expect(status.state == .unknown)
        #expect(status.headline == "No status yet")
        #expect(status.compatibilityNote == "Can’t read Google Drive’s queue right now · checking again")
        let report = try #require(e.compatibility)
        #expect(report.alerting.isEmpty)        // a hiccup, not a change
        var snapshot = Snapshot()
        snapshot.providers = [CompatFixture.provider(.googleDrive, report)]
        snapshot.accounts = [status]
        #expect(snapshot.lidVerdict == .unknown("Velum can’t read Google Drive’s queue"))
    }

    @Test func aChangedQueueTableAlerts() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let (compat, root, driveFS) = try setUp(home, queueSQL: "CREATE TABLE pending_operations (id INTEGER PRIMARY KEY NOT NULL, proto BLOB);")
        let config = GoogleDriveProvider.config(email: "a@b.c", root: root)
        _ = compat.discovered([config], dataFolders: GoogleDriveProvider.dataFolders(in: driveFS, for: [config]), now: Fixture.now)
        _ = compat.queue(config.key, read: GoogleDriveProvider.countOperations(driveFS.appending(path: "123/metadata_sqlite_db").path),
                         now: Fixture.now)
        var e = CompatFixture.evidence([config])
        compat.apply(&e, now: Fixture.now)

        #expect(e.accounts[0].compatibilityNote == "Can’t read Google Drive 134’s queue · only uploads are tracked")
        let report = try #require(e.compatibility)
        #expect(report.alerting.map(\.detail) == ["no operations table"])
        #expect(report.lidReason == "Velum can’t read Google Drive’s queue")
        #expect(CompatibilityText.alertTitle(report) == "Velum can’t read part of Google Drive 134")
    }

    @Test func aStorageRecordThatDoesntAddUpIsOnlyRecorded() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let (compat, root, driveFS) = try setUp(home)
        try CompatFixture.sqlite(driveFS.appending(path: "123/metadata_sqlite_db"),
                                 "INSERT INTO properties (property, value) VALUES ('driveway_account', x'0a0102');")
        let config = GoogleDriveProvider.config(email: "a@b.c", root: root)
        _ = compat.discovered([config], dataFolders: GoogleDriveProvider.dataFolders(in: driveFS, for: [config]), now: Fixture.now)
        _ = compat.queue(config.key, read: 0, now: Fixture.now)
        var e = CompatFixture.evidence([config])
        e.accounts[0].report = GoogleDriveProvider.report(queued: 0, now: Fixture.now)
        compat.apply(&e, now: Fixture.now)

        let report = try #require(e.compatibility)
        let storage = try #require(report.checks.first { $0.name.hasPrefix("storage record") })
        #expect(storage.result == .changed)
        #expect(!storage.alerts)
        #expect(e.accounts[0].compatibilityNote == nil)
        #expect(Fixture.status(e.accounts[0]).state == .ok)
    }

    @Test func foldersFoundThroughDrivesLinksWhenTheNamingChanges() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let (compat, root, _) = try setUp(home, folder: "Google Drive (a@b.c)")
        let found = compat.discovered([], dataFolders: [:], now: Fixture.now)
        #expect(found.configs.map { $0.watchRoots[0].standardizedFileURL.path } == [root.standardizedFileURL.path])
        #expect(found.configs.first.flatMap { found.dataFolders[$0.key] } != nil)
        var e = CompatFixture.evidence(found.configs)
        compat.apply(&e, now: Fixture.now)
        #expect(e.accounts[0].compatibilityNote == "Found from Google Drive 134’s own files · uploads are still tracked")
        #expect(e.compatibility?.alerting.map(\.phrase) == ["folder names"])
    }

    @Test func aMissingDataLinkWaitsAMinuteForANewAccount() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let (compat, root, driveFS) = try setUp(home)
        let mine = GoogleDriveProvider.config(email: "a@b.c", root: root)
        let other = GoogleDriveProvider.config(email: "x@y.z", root: home.appending(path: "Library/CloudStorage/GoogleDrive-x@y.z"))
        let folders = GoogleDriveProvider.dataFolders(in: driveFS, for: [mine, other])
        #expect(folders.keys.sorted() == [mine.key])
        _ = compat.discovered([mine, other], dataFolders: folders, now: Fixture.now)
        var young = CompatFixture.evidence([mine, other])
        compat.apply(&young, now: Fixture.now)
        #expect(young.accounts[1].compatibilityNote == nil)

        _ = compat.discovered([mine, other], dataFolders: folders, now: Fixture.now.addingTimeInterval(61))
        var old = CompatFixture.evidence([mine, other])
        compat.apply(&old, now: Fixture.now.addingTimeInterval(61))
        #expect(old.accounts[0].compatibilityNote == nil)
        #expect(old.accounts[1].compatibilityNote == "Can’t find this account’s Google Drive 134 data · only uploads are tracked")
        #expect(old.compatibility?.lidReason == "Velum can’t read Google Drive’s queue")
    }

    @Test func linkedRootsAcceptRelativeLinks() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let cloud = home.appending(path: "Library/CloudStorage")
        let driveFS = home.appending(path: "Library/Application Support/Google/DriveFS")
        try FileManager.default.createDirectory(at: cloud.appending(path: "GoogleDrive-a@b.c/My Drive"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: driveFS.appending(path: "7"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: driveFS.appending(path: "7/my-drive").path,
                                                   withDestinationPath: "../../../../CloudStorage/GoogleDrive-a@b.c/My Drive")
        let compat = GoogleDriveCompatibility(cloudStorage: cloud, driveFS: driveFS)
        #expect(compat.linkedRoots().map(\.lastPathComponent) == ["GoogleDrive-a@b.c"])
    }
}

@Suite struct ICloudChecks {
    let healthy = "1 containers matching 'com.apple.CloudDocs'\n<c{1}m.a{3}e.C{7}s[1] foreground {client:idle server:full-sync sync:oob-sync-ack, caught-up}>"

    @Test func brctlAnswers() {
        #expect(ICloudCompatibility.statusResult(healthy, brctlExists: true)?.0 == .fine)
        #expect(ICloudCompatibility.statusResult("Status: everything synced", brctlExists: true)?.0 == .changed)
        #expect(ICloudCompatibility.statusResult("<container {state:ok}>", brctlExists: true)?.0 == .changed)
        #expect(ICloudCompatibility.statusResult(nil, brctlExists: true) == nil)     // timed out: a hiccup
        #expect(ICloudCompatibility.statusResult(nil, brctlExists: false)?.0 == .changed)
        #expect(ICloudCompatibility.quotaResult("5 bytes of quota remaining", brctlExists: true)?.0 == .fine)
        #expect(ICloudCompatibility.quotaResult("quota: 5 GB", brctlExists: true)?.0 == .changed)
    }

    @Test func aChangedStatusReportIsDroppedAndSaysWhy() throws {
        let compat = ICloudCompatibility()
        compat.version = { "28.0" }
        compat.brctlExists = { true }
        let changed = compat.record(status: "Status: everything synced", quota: "quota: 5 GB")
        #expect(changed.statusChanged && changed.quotaChanged)
        var e = CompatFixture.evidence([Fixture.iCloud()])
        compat.apply(&e)
        #expect(e.accounts[0].compatibilityNote == "Can’t read iCloud’s status report on macOS 28.0 · uploads are still tracked")
        let report = try #require(e.compatibility)
        #expect(report.alerting.map(\.phrase) == ["status report"])     // the quota is only recorded
        #expect(CompatibilityText.alertTitle(report) == "Velum can’t read part of iCloud on macOS 28.0")
        #expect(CompatibilityText.alertBody(report) == "Velum isn’t using iCloud’s status report for now. Open Cloud Sync to see what’s affected.")
        // A later timeout keeps the result; a good answer clears it.
        let timedOut = compat.record(status: nil, quota: nil)
        #expect(!timedOut.statusChanged && !timedOut.quotaChanged)
        var still = CompatFixture.evidence([Fixture.iCloud()])
        compat.apply(&still)
        #expect(still.accounts[0].compatibilityNote != nil)
        compat.record(status: healthy, quota: "5 bytes of quota remaining")
        var fixed = CompatFixture.evidence([Fixture.iCloud()])
        compat.apply(&fixed)
        #expect(fixed.accounts[0].compatibilityNote == nil)
    }
}

@MainActor
@Suite struct CompatibilityAlerting {
    func changedReport(_ version: String) -> CompatibilityReport {
        CompatibilityReport(provider: .oneDrive, version: version, checks: [
            InternalCheck(name: "status report", accountKey: "Personal", result: .changed, phrase: "status report"),
            InternalCheck(name: "activity list", accountKey: "Personal", result: .changed, phrase: "activity list"),
        ])
    }

    func snapshot(_ report: CompatibilityReport) -> Snapshot {
        var s = Snapshot()
        s.providers = [CompatFixture.provider(.oneDrive, report)]
        s.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive()))]
        return s
    }

    @Test func oncePerReleaseAfterAMinute_rememberedAcrossLaunches() {
        let defaults = CompatFixture.defaults()
        let notifier = Notifier()
        notifier.compatibility = CompatibilityAlerts(defaults: defaults)
        var shown: [(String, String)] = []
        notifier.fallback = { title, body, _ in shown.append((title, body)) }
        let broken = snapshot(changedReport("27.0.1001"))
        notifier.update(broken, enabled: true, now: Fixture.now)
        notifier.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(30))
        #expect(shown.isEmpty)
        notifier.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(61))
        notifier.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(200))
        #expect(shown.map(\.0) == ["Velum can’t read part of OneDrive 27.0"])
        #expect(shown.first?.1 == "Velum isn’t using OneDrive’s status report and activity list for now. Open Cloud Sync to see what’s affected.")

        // Fixed, then broken again on the same release, or after a relaunch: still that one alert.
        notifier.update(snapshot(CompatibilityReport(provider: .oneDrive, version: "27.0.1001")), enabled: true, now: Fixture.now.addingTimeInterval(300))
        let relaunched = Notifier()
        relaunched.compatibility = CompatibilityAlerts(defaults: defaults)
        relaunched.fallback = notifier.fallback
        relaunched.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(400))
        relaunched.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(500))
        #expect(shown.count == 1)

        // The next release that changes something alerts again; a new build of the same release doesn't.
        relaunched.update(snapshot(changedReport("27.0.1002")), enabled: true, now: Fixture.now.addingTimeInterval(600))
        relaunched.update(snapshot(changedReport("27.0.1002")), enabled: true, now: Fixture.now.addingTimeInterval(700))
        #expect(shown.count == 1)
        relaunched.update(snapshot(changedReport("27.4.1000")), enabled: true, now: Fixture.now.addingTimeInterval(800))
        relaunched.update(snapshot(changedReport("27.4.1000")), enabled: true, now: Fixture.now.addingTimeInterval(900))
        #expect(shown.map(\.0).last == "Velum can’t read part of OneDrive 27.4")
    }

    @Test func alertsOffStillMarkTheReleaseAsTold() {
        let defaults = CompatFixture.defaults()
        let notifier = Notifier()
        notifier.compatibility = CompatibilityAlerts(defaults: defaults)
        var shown = 0
        notifier.fallback = { _, _, _ in shown += 1 }
        let broken = snapshot(changedReport("27.0.1001"))
        notifier.update(broken, enabled: false, now: Fixture.now)
        notifier.update(broken, enabled: false, now: Fixture.now.addingTimeInterval(61))
        notifier.update(broken, enabled: true, now: Fixture.now.addingTimeInterval(120))
        #expect(shown == 0)
    }

    @Test func pendingAndFailingWorkStillComeFirstOnTheLid() {
        var queue = InternalCheck(name: "queue", result: .unavailable, guardsLid: true)
        queue.lidReason = CompatibilityText.lidQueue
        var s = Snapshot()
        s.providers = [CompatFixture.provider(.googleDrive, CompatibilityReport(provider: .googleDrive, version: "134.0", checks: [queue]))]
        var uploads = UploadSummary()
        uploads.waiting = 2
        let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c")
        s.accounts = [Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root)), uploads: uploads)]
        #expect(s.lidVerdict == .pending(2))
        s.accounts = [Fixture.status(Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root)))]
        #expect(s.lidVerdict == .unknown("Velum can’t read Google Drive’s queue"))
    }

    @Test func theDebugLogSaysWhatMoved() {
        let fine = CompatibilityReport(provider: .oneDrive, version: "26.212.1029", checks: [
            InternalCheck(name: "status report", accountKey: "Personal", accountName: "Personal", result: .fine, detail: "code 0"),
        ])
        var broken = fine
        broken.checks[0].result = .changed
        broken.checks[0].detail = "no SyncProgressState line"
        #expect(fine.changes(from: nil) == ["OneDrive 26.212 (26.212.1029) · tested · every check passes"])
        #expect(fine.changes(from: fine).isEmpty)
        #expect(CompatibilityReport(provider: .iCloud, version: "27.3").headline == "macOS 27.3, for iCloud · tested · nothing checked yet")
        #expect(broken.changes(from: fine) == ["OneDrive: XX  status report · Personal: changed (no SyncProgressState line)"])
    }
}
