import Foundation
import Testing
@testable import Velum

/// Card S2: the redaction corpus. Every account, address, organization, path and file name here is made up,
/// with Unicode, spaces, and names that are also ordinary words. A whole report is built from them, and none
/// may survive into it.
@Suite struct DiagnosticsRedaction {
    static let home = "/Users/test"
    static let cloud = "/Users/test/Library/CloudStorage"
    static let now = Fixture.now

    /// What must never appear in the report, in any case.
    static let personal = [
        // Organizations and account names (one is an ordinary word, one has Unicode, spaces and "&").
        "Zürich Café & Co", "Zürich", "Delta", "Old Org", "Former Partners",
        // Google accounts, also inside GoogleDrive-<email> folder names; one in decomposed Unicode in the log.
        "zoë.ng@example.org", "zoë", "team@delta.example", "former@example.net", "stranger@example.com",
        // DriveFS's numeric account IDs.
        "117234567890123456789", "104876543210987654321",
        // The home folder, the user's names, the Mac's name, a volume.
        "/Users/test", "Zoë Sample", "MacBook of Zoë", "Backup Disk",
        // File names (the extension may stay) and folders inside synced folders.
        "Budget 2027", "Résumé – final", "日本語のファイル", "notes.txt", "Draft (v3)", "Q4 review", "Paused.pdf",
        "Gone Budget", "Lost Notes", "Minutes March", "Secret Plans", "Taxes 2026", "Board",
        // Storage figures, a storage percentage, a sign-in token, a SharePoint tenant.
        "214 GB", "400 GB", "1.27 TB", "9 GB", "12 MB", "40 MB", "1272173412087", "95%",
        "ya29.", "1//0g", "zoe_delta", "delta-my",
    ]

    static func oneDrive(_ key: String, _ name: String) -> AccountConfig {
        let folder = URL(fileURLWithPath: "\(cloud)/OneDrive-\(name)")
        return AccountConfig(key: key, provider: .oneDrive, folder: folder, watchRoots: [folder],
                             places: [NamedRoot(path: folder.path, name: folder.lastPathComponent, prefixed: false)],
                             fallbackName: OneDriveFiles.fallbackName(kind: key == "Personal" ? .personal : .business, folder: folder),
                             webURL: URL(string: "https://delta-my.sharepoint.com/personal/zoe_delta_example/_layouts/15/onedrive.aspx")!)
    }

    static func google(_ email: String) -> AccountConfig {
        GoogleDriveProvider.config(email: email, root: URL(fileURLWithPath: "\(cloud)/GoogleDrive-\(email)"))
    }

    static func line(_ minutesAgo: Double, _ text: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "\(f.string(from: now.addingTimeInterval(-minutesAgo * 60))) \(text)"
    }

    static func input() -> DiagnosticsInput {
        let personal = oneDrive("Personal", "Personal")
        let zurich = oneDrive("Business1", "Zürich Café & Co")
        let delta = oneDrive("Business2", "Delta")
        let iCloud = Fixture.iCloud()
        let zoe = google("zoë.ng@example.org")
        let team = google("team@delta.example")

        var a = AccountEvidence(config: personal, name: "Personal")
        a.report = ProviderReport(label: "OneDrive report", written: now.addingTimeInterval(-600), state: .ok,
                                  headline: "Up to date", every: OneDriveProvider.reportEvery)
        var b = AccountEvidence(config: zurich, name: "Zürich Café & Co")
        b.notes = ["Can’t read OneDrive 27.0’s status report · uploads are still tracked"]
        var c = AccountEvidence(config: delta, name: "Delta")
        c.exactStatus = "OneDrive is 95% full"
        var d = AccountEvidence(config: iCloud, name: "iCloud Drive")
        d.notes = ["Desktop & Documents included", "1.27 TB free"]
        d.storageSource = "brctl quota"
        var e = AccountEvidence(config: zoe, name: zoe.fallbackName)
        e.report = GoogleDriveProvider.report(queued: 3, now: now)
        e.notes = ["Almost full · 9 GB free of 400 GB"]
        e.storageSource = "Google Drive’s cache on this Mac"
        var f = AccountEvidence(config: team, name: team.fallbackName)
        f.report = GoogleDriveProvider.pausedReport(now: now)
        f.notes = ["214 GB free of 400 GB", "Storage not shown · the Google sign-in is for stranger@example.com"]
        f.storageSource = "none (Google Drive’s cache has no figures)"

        var failing = UploadSummary()
        failing.failed = ["Résumé – final.docx: The file “Résumé – final.docx” couldn’t be uploaded because you don’t have permission to access “Zürich Café & Co”."]
        var waiting = UploadSummary()
        waiting.waiting = 2
        waiting.oldestWaiting = now.addingTimeInterval(-3 * 3600)
        let transfer = TransferInfo(uploadingFiles: 1, downloadingFiles: 0, otherFiles: 0, bytesDone: 12_582_912, bytesTotal: 41_943_040)

        var snapshot = Snapshot()
        snapshot.providers = [
            ProviderStatus(id: .oneDrive, clientRunning: true, trouble: nil, compatibility: CompatibilityReport(
                provider: .oneDrive, version: "26.212.1029", checks: [
                    InternalCheck(name: "settings (libraryScope lines)", result: .fine, detail: "3 accounts"),
                    InternalCheck(name: "status report (SyncDiagnostics.log)", accountKey: "Business1", accountName: "Zürich Café & Co",
                                  result: .changed, detail: "no SyncProgressState line"),
                    InternalCheck(name: "live folders", result: .unavailable,
                                  detail: "live folder not watched: OneDrive-SharedLibraries-Zürich Café & Co, OneDrive-Former Partners",
                                  guardsLid: true),
                ])),
            ProviderStatus(id: .iCloud, clientRunning: nil, compatibility: CompatibilityReport(provider: .iCloud, version: "27.3", checks: [
                InternalCheck(name: "status report (brctl status)", result: .fine, detail: "client:idle, caught-up"),
                InternalCheck(name: "storage (brctl quota)", result: .fine, quiet: true),
            ])),
            ProviderStatus(id: .googleDrive, clientRunning: true, trouble: "Storage full", compatibility: CompatibilityReport(
                provider: .googleDrive, version: "133.0.2", checks: [
                    InternalCheck(name: "account data (my-drive link)", accountKey: zoe.key, accountName: zoe.fallbackName, result: .fine, detail: "linked"),
                    InternalCheck(name: "queue (operations table)", accountKey: zoe.key, accountName: zoe.fallbackName, result: .fine, detail: "3 queued"),
                    InternalCheck(name: "folder names (GoogleDrive-<email>)", result: .changed,
                                  detail: "no GoogleDrive- folder, but Drive links to GoogleDrive-former@example.net"),
                ])),
        ]
        func status(_ evidence: AccountEvidence, _ uploads: UploadSummary = UploadSummary(), _ t: TransferInfo? = nil) -> AccountStatus {
            Collector.status(evidence, transfer: t, uploads: uploads, watchingUploads: true, now: now)
        }
        snapshot.accounts = [status(a), status(b, failing), status(c, waiting, transfer), status(d), status(e), status(f)]
        snapshot.activity = [
            Activity(accountKey: "Business2", path: "\(cloud)/OneDrive-Delta/Plans/Q4 review.pptx", name: "Q4 review.pptx",
                     kind: 5, date: now.addingTimeInterval(-300), app: "Keynote"),
            Activity(accountKey: "Personal", path: "\(cloud)/OneDrive-Personal/Paused.pdf", name: "Paused.pdf",
                     kind: 4, date: now.addingTimeInterval(-900), app: nil),
        ]
        let stuck = [
            PendingFile(account: "Business1", path: "\(cloud)/OneDrive-Zürich Café & Co/Plans/Secret Plans/Budget 2027.xlsx",
                        since: now.addingTimeInterval(-7200), status: .failed("The file “Budget 2027.xlsx” is too large.")),
            PendingFile(account: "iCloudDrive", path: "\(home)/Documents/Taxes 2026/日本語のファイル.pdf",
                        since: now.addingTimeInterval(-5400), status: .waiting),
            PendingFile(account: zoe.key, path: "\(cloud)/GoogleDrive-zoë.ng@example.org/My Drive/notes.txt",
                        since: now.addingTimeInterval(-4000), status: .uploading),
            PendingFile(account: "Business2", path: "\(cloud)/OneDrive-Delta/Draft (v3).pages",
                        since: now.addingTimeInterval(-3000), status: .waiting),
        ]
        snapshot.stuck = PendingList(files: stuck, total: 5, perAccount: ["Business1": 1, "iCloudDrive": 1, zoe.key: 1, "Business2": 2])

        var input = DiagnosticsInput(origin: .app, now: now, snapshot: snapshot, transfers: ["Business2": transfer], home: home)
        input.velumVersion = "Velum 1.0"
        input.macOS = "Version 27.3 (Build 26C5035r)"
        input.model = "Mac14,6"
        input.chip = "Apple M2 Max"
        input.language = "en-US, format en_US"
        input.openAtLogin = true
        input.googleSignInAvailable = true
        input.googleSignInOn = ["team@delta.example"]
        input.oneDriveReports = [
            "Personal": .read(Diagnostics(written: now.addingTimeInterval(-600), progressState: 16777216, pid: 4242,
                                          filesToUpload: 0, filesToDownload: 1, files: 5120, folders: 300)),
            "Business1": .unreadable,
            "Business2": .missing,
        ]
        input.googlePaused = false
        input.userNames = ["test", "Zoë Sample", "Zoë", "Sample"]
        input.computerName = "MacBook of Zoë"
        input.driveFSIDs = ["104876543210987654321", "117234567890123456789"]
        input.log.lines = [
            line(300, "[log] Debug logging turned on · Velum 1.0 · macOS Version 27.3 on MacBook of Zoë"),
            line(299, "[status] Personal [OneDrive]: appeared · Up to date · OneDrive report, 1:45 PM"),
            line(299, "[status] Old Org [OneDrive]: appeared · Up to date · OneDrive report, 1:45 PM"),
            line(250, "[status] Old Org: ok → syncing · Uploading 1 file · Live from macOS · 1 pending"),
            line(240, "[status] Old Org [OneDrive]: gone"),
            line(200, "[status] Zürich Café & Co: 1 failing · first: Gone Budget.key: The file “Gone Budget.key” couldn’t be uploaded."),
            line(190, "[alert] Delta: 1 file can’t upload · Lost Notes.rtf: The operation couldn’t be completed."),
            line(180, "[google] former@example.net: Google Drive's queue is empty"),
            line(170, "[tracker] googledrive:zoe\u{308}.ng@example.org: macOS dropped change events (flags 0x2); can't vouch for 15 minutes"),
            line(160, "[google] Google sign-in didn't finish: otherAccount(\"stranger@example.com\")"),
            line(150, "[google] stray ya29.a0AfH6SMBexampleexample and 1//0gExampleRefreshToken123 in an error"),
            line(140, "[compat] OneDrive: !!  live folders: live folder not watched: OneDrive-SharedLibraries-Zürich Café & Co, OneDrive-Former Partners"),
            line(130, "[compat] Google Drive: XX  folder names (GoogleDrive-<email>): changed (no GoogleDrive- folder, but Drive links to GoogleDrive-former@example.net)"),
            line(120, "[status] Delta: Almost full · 9 GB free of 400 GB"),
            line(110, "[action] opened https://delta-my.sharepoint.com/personal/zoe_delta_example/_layouts/15/onedrive.aspx"),
            line(100, "[tracker] saw /Users/test/Library/CloudStorage/OneDrive-Delta/Board/Minutes March.docx change"),
            line(90, "[icloud] brctl read /Volumes/Backup Disk/Old/report.txt · 1272173412087 bytes of quota remaining"),
            line(80, "[google] DriveFS/117234567890123456789/metadata_sqlite_db was busy"),
            line(70, "[status] Lid: busy(\"Delta\")"),
        ]
        input.log.total = input.log.lines.count
        return input
    }

    static func survivors(_ text: String) -> [String] {
        let report = Redactor.nfc(text).lowercased()
        return personal.filter { report.contains(Redactor.nfc($0).lowercased()) }
    }

    @MainActor @Test func nothingPersonalSurvivesTheWholeReport() {
        let report = DiagnosticsReport.render(Self.input())
        #expect(Self.survivors(report) == [])
    }

    @MainActor @Test func theReportStillSaysWhatHappened() {
        let report = DiagnosticsReport.render(Self.input())
        for kept in ["Velum diagnostics (redacted)", "Account 1 · OneDrive · key Personal", "Account 2 · OneDrive · key Business1",
                     "Account 5 · Google Drive", "OneDrive 26.212.1029", "SyncProgressState 16777216 · FilesToUpload 0 · FilesToDownload 1",
                     "brctl status: client:idle, caught-up", "Google Drive’s queue: 3 queued · paused: no",
                     "storage: Google Drive’s cache on this Mac", "storage: brctl quota", "none (OneDrive gives Velum none)",
                     "<size> free of <size>", "<percent> full", "<url at sharepoint.com>", "<token>", "otherAccount(\"<email 1>\")",
                     "DriveFS/<id 2>/metadata_sqlite_db", "OneDrive-SharedLibraries-Account 2, OneDrive-<org 1> (the lid",
                     "Drive links to GoogleDrive-Account 8)", "folder names (GoogleDrive-<email>)", "Account 3: Almost full",
                     "/Volumes/<volume>/…/file-", ".txt · <size> of quota remaining", "Lid: busy(\"Account 3\")",
                     "OneDrive-Account 2", "GoogleDrive-Account 5", "~/Documents/…/", ".xlsx", ".pdf", ".pages", "Debug log",
                     "Not in the cloud yet: 5 files", "the first 4 listed", "transfers: up 1 · down 0 · direction unknown 0 · 30% of the bytes",
                     "Google sign-in: Account 5 off, Account 6 on", "Not everything is in the cloud. 1 file can’t upload.",
                     "Open at Login: on"] {
            #expect(report.contains(kept), "missing: \(kept)")
        }
    }

    @MainActor @Test func aNameGetsTheSameLabelEverywhere() {
        let input = Self.input()
        let (r, labels) = DiagnosticsReport.redactor(for: input)
        let file = r.file("Résumé – final.docx")
        #expect(file.hasPrefix("file-") && file.hasSuffix(".docx"))
        let report = DiagnosticsReport.render(input)
        // The failing file is named in the row's first failure and in its own reason, with one label.
        #expect(report.components(separatedBy: file).count >= 3)
        #expect(labels["Business1"] == "Account 2")
        // An account only the log knows gets the next number, in every line that names it.
        #expect(report.contains("Account 7 [OneDrive]: appeared"))
        #expect(report.contains("Account 7: ok → syncing"))
        #expect(report.contains("Account 7 [OneDrive]: gone"))
    }

    @Test func pathsKeepTheSyncedFolderAndTheExtensionOnly() {
        let r = Redactor(home: "/Users/test")
        r.account(["Zürich Café & Co"])
        r.root("/Users/test/Library/CloudStorage/OneDrive-Zürich Café & Co")
        #expect(r.path("/Users/test/Library/CloudStorage/OneDrive-Zürich Café & Co/A/B C/Report final.docx")
                == "~/Library/CloudStorage/OneDrive-Account 1/…/file-1.docx")
        #expect(r.path("/Users/test/Library/CloudStorage/OneDrive-Zürich Café & Co") == "~/Library/CloudStorage/OneDrive-Account 1")
        #expect(r.path("/Users/test/Elsewhere/Secret.key") == "~/…/file-2.key")
        #expect(r.path("/Users/tester/x.txt") == "/…/file-3.txt")
        #expect(r.text("see /Users/test/Library/CloudStorage/OneDrive-Zürich Café & Co/Deep/Folder/Report final.docx")
                == "see ~/Library/CloudStorage/OneDrive-Account 1/…/file-1.docx")
    }

    @Test func ordinaryWordsGoOnlyAsWholeWords() {
        let r = Redactor(home: "/Users/test")
        r.account(["Delta", "Personal"])
        // "Delta" goes wherever it is a word, in any case; "Deltas" is another word; "Personal" is OneDrive's own.
        #expect(r.text("Delta, DELTA and delta-my are Deltas · Personal") == "Account 1, Account 1 and Account 1-my are Deltas · Personal")
        // Shorter than three characters: not swept from free text.
        r.file("a")
        #expect(r.text("a file") == "a file")
    }

    @Test func decomposedUnicodeMatchesItsComposedForm() {
        let r = Redactor(home: "/Users/test")
        r.account(["zoë.ng@example.org", "Café"])
        #expect(r.text("zoe\u{308}.ng@example.org and Cafe\u{301}") == "Account 1 and Account 1")
    }

    @Test func foreignTextLosesQuotesAndFileNames() {
        let r = Redactor(home: "/Users/test")
        let line = "The file “Plan B.key” couldn’t be saved in “Summit Folder”. See Velum.log and Board.docx."
        #expect(r.foreign(line) == "The file “file-1.key” couldn’t be saved in “…”. See Velum.log and file-2.docx.")
        // Velum's own text keeps its quotes.
        #expect(r.text("OneDrive last reported “Up to date”") == "OneDrive last reported “Up to date”")
    }

    @Test func recentLogKeepsTheLastDayAcrossBothFilesUpToTheCap() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-diag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = [Self.line(26 * 60, "[status] two days ago"), Self.line(20 * 60, "[status] older file, still today")]
        let new = (0..<5).map { Self.line(Double(10 - $0), "[status] line \($0)") } + ["a continuation without a time"]
        try (old.joined(separator: "\n") + "\n").write(to: dir.appending(path: "Velum.1.log"), atomically: true, encoding: .utf8)
        try (new.joined(separator: "\n") + "\n").write(to: dir.appending(path: "Velum.log"), atomically: true, encoding: .utf8)

        let all = DiagnosticsReport.recentLog(in: dir, now: Self.now)
        #expect(all.total == 7)
        #expect(all.lines.first?.hasSuffix("older file, still today") == true)
        #expect(all.lines.last == "a continuation without a time")
        let capped = DiagnosticsReport.recentLog(in: dir, now: Self.now, limit: 3)
        #expect(capped.total == 7 && capped.lines.count == 3)
        #expect(capped.lines.first?.hasSuffix("line 3") == true)
        #expect(DiagnosticsReport.recentLog(in: dir.appending(path: "none"), now: Self.now).lines.isEmpty)
    }

    @Test func exportWritesANewTextFileEachTime() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try DiagnosticsReport.write("one", in: dir, now: Self.now)
        let second = try DiagnosticsReport.write("two", in: dir, now: Self.now)
        #expect(first.lastPathComponent.hasPrefix("Velum Diagnostics ") && first.pathExtension == "txt")
        #expect(second.lastPathComponent == String(first.lastPathComponent.dropLast(4)) + " 2.txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two")
    }

    @Test func storageSourceReachesTheRow() {
        var evidence = Fixture.evidence(Fixture.iCloud())
        evidence.storageSource = "brctl quota"
        #expect(Fixture.status(evidence).storageSource == "brctl quota")
    }
}
