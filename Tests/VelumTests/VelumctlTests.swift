import Foundation
import Testing
@testable import Velum
@testable import VelumStatus

// T1: the status file and velumctl. Every snapshot here is made up; files go to a throwaway temporary folder.

private let now = Fixture.now
private let alive: (Int32) -> Bool = { _ in true }

/// A small document with the given lid, written `age` seconds before `now`.
private func document(_ lid: Lid = .safe, age: TimeInterval = 1, refreshEvery: Double = 2.5) -> StatusDocument {
    StatusDocument(written: now.addingTimeInterval(-age), refreshEvery: refreshEvery,
                   app: AppInfo(version: "1.0", build: "1", pid: 4242), state: .ok, summary: "Up to date", lid: lid,
                   services: [Service(id: "onedrive", name: "OneDrive", appRunning: true, trouble: nil, paused: nil, compatibility: nil)],
                   accounts: [Account(key: "Personal", service: "onedrive", name: "Personal", state: .ok, headline: "Up to date",
                                      detail: nil, source: nil, age: "live", old: false, reason: nil, notes: nil,
                                      notesNeedAttention: false, headlineFromApp: false, lastChange: nil,
                                      uploads: Uploads(pending: 0, failed: 0, stuck: 0, oldestWaiting: nil, firstFailure: nil,
                                                       covered: true, serviceBusy: false, serviceBusySince: nil),
                                      storage: nil)],
                   pending: Pending(total: 0, stuck: 0, stuckAfter: 600, files: []))
}

private func data(_ document: StatusDocument) -> Data { try! StatusDocument.encoder().encode(document) }

private func interpreted(_ document: StatusDocument, running: Bool = true) -> StatusReading {
    StatusReading.interpret(data(document), now: now, isRunning: { _ in running })
}

private func run(_ arguments: String..., reading: StatusReading = interpreted(document())) -> VelumCtl.Output {
    VelumCtl.run(arguments, version: "1.0 (1)") { reading }
}

/// Every key path in a JSON value: "accounts[].uploads.pending".
private func keyPaths(_ json: Any, _ prefix: String = "") -> Set<String> {
    if let object = json as? [String: Any] {
        return object.reduce(into: Set<String>()) { paths, entry in
            let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
            paths.insert(path)
            paths.formUnion(keyPaths(entry.value, path))
        }
    }
    if let array = json as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, prefix + "[]")) } }
    return []
}

private func keyPaths(_ data: Data) -> Set<String> { keyPaths(try! JSONSerialization.jsonObject(with: data)) }

@Suite struct ExitCodes {
    @Test func everyVerdictHasItsCode() {
        #expect(run("lid", reading: interpreted(document(.safe))).code == 0)
        #expect(run("lid", reading: interpreted(document(.pending(3)))).code == 1)
        #expect(run("lid", reading: interpreted(document(.busy("alex@example.com")))).code == 1)
        #expect(run("lid", reading: interpreted(document(.failing(1)))).code == 2)
        #expect(run("lid", reading: interpreted(document(.notRunning("OneDrive")))).code == 2)
        #expect(run("lid", reading: interpreted(document(.unknown("Velum may have missed recent changes in Personal")))).code == 3)
    }

    @Test func everyCommandExitsWithTheLidsCode() {
        for command in VelumCtl.Command.allCases {
            #expect(run(command.rawValue, reading: interpreted(document(.pending(2)))).code == 1)
            #expect(run(command.rawValue, "--json", reading: interpreted(document(.failing(1)))).code == 2)
        }
    }

    @Test func usageErrorsAre64AndHelpAndVersionAreZero() {
        // No command means status.
        #expect(run().code == 0 && run().stdout == run("status").stdout && run().stderr.isEmpty)
        #expect(run("--json").stdout == run("status", "--json").stdout)
        #expect(run("lids").code == 64)
        #expect(run("lids").stdout.isEmpty && run("lids").stderr.contains("usage: velumctl"))
        #expect(run("lid", "pending").code == 64)
        #expect(run("lid", "--verbose").code == 64)
        #expect(run("--help").code == 0 && run("--help").stdout.contains("64  usage error"))
        #expect(run("--version").stdout == "velumctl 1.0 (1) · status schema 1\n")
        #expect(run("--version").code == 0)
        // --json may come first.
        #expect(run("--json", "lid").code == 0)
    }
}

@Suite struct Freshness {
    @Test func freshUntilTwoRefreshIntervals() {
        #expect(interpreted(document(age: 4.9)).fresh)
        let late = interpreted(document(age: 5.5))
        #expect(!late.fresh && late.lid.verdict == .unknown && late.lid.exitCode == 3)
        #expect(late.lid.detail == "Velum’s last status is 5 seconds old. Things may have changed since.")
        if case .stale(let age) = late.problem { #expect(abs(age - 5.5) < 0.01) } else { Issue.record("not stale") }
        // A slower app says so, and the limit follows; a tiny interval never makes it stricter than 5 s.
        #expect(interpreted(document(age: 50, refreshEvery: 30)).fresh)
        #expect(!interpreted(document(age: 61, refreshEvery: 30)).fresh)
        #expect(interpreted(document(age: 4.9, refreshEvery: 0.1)).fresh)
        // A file can't claim more than 30 s between refreshes, and nonsense counts as 2.5 s. (JSON can't carry
        // infinity or NaN at all.)
        #expect(!interpreted(document(age: 61, refreshEvery: 1e9)).fresh)
        #expect(!interpreted(document(age: 6, refreshEvery: -1)).fresh)
        #expect(!interpreted(document(age: 6, refreshEvery: 0)).fresh)
    }

    @Test func staleNeverGivesTheLastGoodAnswer() {
        let stale = interpreted(document(.safe, age: 4 * 60))
        #expect(stale.document == nil)
        #expect(stale.lid.verdict == .unknown)
        #expect(stale.lid.detail == "Velum’s last status is 4 minutes old. Things may have changed since.")
        let output = run("status", reading: stale)
        #expect(output.code == 3)
        #expect(!output.stdout.contains("Personal") && !output.stdout.contains("Safe to close"))
        let json = try! JSONSerialization.jsonObject(with: Data(run("status", "--json", reading: stale).stdout.utf8)) as! [String: Any]
        #expect(json["fresh"] as? Bool == false)
        #expect(json["accounts"] == nil && json["services"] == nil && json["pending"] == nil)
        #expect((json["lid"] as? [String: Any])?["verdict"] as? String == "unknown")
    }

    @Test func missingFile() {
        let url = FileManager.default.temporaryDirectory.appending(path: "velum-tests-\(UUID().uuidString)/status.json")
        let missing = StatusReading.read(url, now: now, isRunning: alive)
        #expect(missing.problem == .missing && missing.lid.exitCode == 3)
        #expect(missing.lid.detail == "There’s no status from Velum yet. It isn’t running, or has only just started.")
        #expect(run("lid", reading: missing).stdout
                == "Can’t vouch for every change. There’s no status from Velum yet. It isn’t running, or has only just started.\n")
    }

    @Test func aFileThatCantBeReadIsNotMissing() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "velum-tests-\(UUID().uuidString)/status.json")
        try document().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        let locked = StatusReading.read(url, now: now, isRunning: alive)
        #expect(locked.problem == .unreadable && locked.lid.exitCode == 3)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @Test func safeMustAgreeWithTheRestOfTheFile() {
        var d = document(.safe)
        #expect(interpreted(d).fresh)
        d.accounts[0].uploads.pending = 1
        #expect(interpreted(d).problem == .inconsistent && interpreted(d).lid.exitCode == 3)
        d = document(.safe); d.accounts[0].uploads.covered = false
        #expect(interpreted(d).problem == .inconsistent)
        d = document(.safe); d.services[0].appRunning = false
        #expect(interpreted(d).problem == .inconsistent)
        d = document(.safe); d.accounts[0].uploads.serviceBusy = true
        #expect(interpreted(d).problem == .inconsistent)
        d = document(.safe); d.accounts = []
        #expect(interpreted(d).problem == .inconsistent)
        // The stored exit code is never what decides: it is redone from the verdict.
        var tampered = try! JSONSerialization.jsonObject(with: data(document(.pending(1)))) as! [String: Any]
        var lid = tampered["lid"] as! [String: Any]
        lid["exitCode"] = 0
        tampered["lid"] = lid
        let read = StatusReading.interpret(try! JSONSerialization.data(withJSONObject: tampered), now: now, isRunning: alive)
        #expect(read.lid.exitCode == 1 && run("lid", reading: read).code == 1)
    }

    @Test func aVelumThatQuitIsUnknownEvenWhenFresh() {
        let quit = interpreted(document(.safe, age: 1), running: false)
        #expect(quit.problem == .appNotRunning && quit.lid.exitCode == 3)
        #expect(quit.lid.detail == "Velum isn’t running.")
    }

    @Test func newerSchemaIsRefused() throws {
        var object = try JSONSerialization.jsonObject(with: data(document())) as! [String: Any]
        object["schema"] = 2
        object["somethingNew"] = ["a": 1]
        let newer = StatusReading.interpret(try JSONSerialization.data(withJSONObject: object), now: now, isRunning: alive)
        #expect(newer.problem == .newerSchema(2) && newer.lid.exitCode == 3 && newer.document == nil)
        #expect(newer.lid.detail == "This velumctl is older than the running Velum. Use the one inside Velum.app.")
        // Even a newer file that wouldn't decode at all as schema 1 says "newer", not "can't be read".
        let bare = StatusReading.interpret(Data(#"{"schema": 7}"#.utf8), now: now, isRunning: alive)
        #expect(bare.problem == .newerSchema(7))
    }

    @Test func unreadableAndFutureAreUnknown() throws {
        #expect(StatusReading.interpret(Data("not json".utf8), now: now, isRunning: alive).problem == .unreadable)
        #expect(StatusReading.interpret(Data(#"{"schema": 1}"#.utf8), now: now, isRunning: alive).problem == .unreadable)
        #expect(StatusReading.interpret(Data(#"{"schema": 0}"#.utf8), now: now, isRunning: alive).problem == .unreadable)
        // Unknown keys within schema 1 are fine.
        var object = try JSONSerialization.jsonObject(with: data(document())) as! [String: Any]
        object["addedLater"] = true
        #expect(StatusReading.interpret(try JSONSerialization.data(withJSONObject: object), now: now, isRunning: alive).fresh)
        let future = interpreted(document(age: -120))
        #expect(future.problem == .future && future.lid.exitCode == 3)
        #expect(interpreted(document(age: -0.5)).fresh)
        #expect(interpreted(document(age: -1.5)).problem == .future)
    }
}

@Suite struct Schema {
    /// Every key the status file can carry, with every optional filled. Changing this list is a schema decision:
    /// renaming or removing a key bumps `StatusDocument.schemaVersion`, and docs/velumctl.md follows.
    static let documentKeys: Set<String> = [
        "schema", "written", "refreshEvery", "state", "summary",
        "app", "app.version", "app.build", "app.pid",
        "lid", "lid.verdict", "lid.files", "lid.title", "lid.detail", "lid.exitCode",
        "services", "services[].id", "services[].name", "services[].appRunning", "services[].trouble", "services[].paused",
        "services[].compatibility", "services[].compatibility.headline", "services[].compatibility.version",
        "services[].compatibility.tested", "services[].compatibility.checksNotPassing",
        "accounts", "accounts[].key", "accounts[].service", "accounts[].name", "accounts[].state", "accounts[].headline",
        "accounts[].detail", "accounts[].source", "accounts[].age", "accounts[].old", "accounts[].reason", "accounts[].notes",
        "accounts[].notesNeedAttention", "accounts[].headlineFromApp", "accounts[].lastChange",
        "accounts[].uploads", "accounts[].uploads.pending", "accounts[].uploads.failed", "accounts[].uploads.stuck",
        "accounts[].uploads.oldestWaiting", "accounts[].uploads.firstFailure", "accounts[].uploads.covered",
        "accounts[].uploads.serviceBusy", "accounts[].uploads.serviceBusySince",
        "accounts[].storage", "accounts[].storage.limit", "accounts[].storage.used", "accounts[].storage.free",
        "accounts[].storage.usedByFiles", "accounts[].storage.full", "accounts[].storage.source", "accounts[].storage.asOf",
        "pending", "pending.total", "pending.stuck", "pending.stuckAfter", "pending.files", "pending.files[].account",
        "pending.files[].path", "pending.files[].name", "pending.files[].since", "pending.files[].status",
        "pending.files[].reason", "pending.files[].stuck",
    ]

    static var full: StatusDocument {
        var d = document(.pending(2))
        d.services = [Service(id: "googledrive", name: "Google Drive", appRunning: true, trouble: "Storage full", paused: false,
                              compatibility: Compatibility(headline: "Google Drive 133 · tested · every check passes",
                                                           version: "133.0.1", tested: true, checksNotPassing: 0))]
        d.accounts[0] = Account(key: "googledrive:alex.sample@example.com", service: "googledrive", name: "alex.sample@example.com",
                                state: .error, headline: "1 file can't upload", detail: "Live from macOS", source: "Live from macOS",
                                age: "live", old: false, reason: "Why", notes: "Storage full", notesNeedAttention: true,
                                headlineFromApp: false, lastChange: now,
                                uploads: Uploads(pending: 1, failed: 1, stuck: 1, oldestWaiting: now, firstFailure: "a.txt: No room.",
                                                 covered: true, serviceBusy: true, serviceBusySince: now),
                                storage: Storage(limit: 400, used: 400, free: 0, usedByFiles: 100, full: true, source: .googleDriveCache,
                                                 asOf: now))
        d.pending = Pending(total: 1, stuck: 1, stuckAfter: 600, files: [
            VelumStatus.PendingFile(account: "googledrive:alex.sample@example.com",
                                    path: "/Users/test/Library/CloudStorage/GoogleDrive-alex.sample@example.com/My Drive/a.txt",
                                    since: now, status: .failing, reason: "No room.", stuck: true),
        ])
        return d
    }

    @Test func documentKeysDontChangeSilently() {
        #expect(keyPaths(data(Self.full)) == Self.documentKeys)
        #expect(StatusDocument.schemaVersion == 1)
    }

    @Test func lidKeysAcrossEveryVerdict() {
        let lids: [Lid] = [.safe, .pending(1), .busy("A"), .failing(1), .notRunning("OneDrive"), .unknown("Why")]
        let keys = lids.reduce(into: Set<String>()) { $0.formUnion(keyPaths(try! StatusDocument.encoder().encode($1))) }
        #expect(keys == ["verdict", "files", "service", "account", "reason", "title", "detail", "exitCode"])
        #expect(lids.map(\.verdict.rawValue) == ["safe", "pending", "busy", "failing", "notRunning", "unknown"])
    }

    @Test func answerKeysPerCommand() {
        let fresh = interpreted(Self.full)
        func keys(_ command: VelumCtl.Command) -> Set<String> {
            let json = try! StatusDocument.encoder().encode(VelumCtl.answer(command, fresh))
            return Set((try! JSONSerialization.jsonObject(with: json) as! [String: Any]).keys)
        }
        #expect(keys(.lid) == ["schema", "fresh", "written", "ageSeconds", "lid"])
        #expect(keys(.pending) == ["schema", "fresh", "written", "ageSeconds", "lid", "pending"])
        #expect(keys(.status) == ["schema", "fresh", "written", "ageSeconds", "lid", "refreshEvery", "app", "state", "summary",
                                  "services", "accounts", "pending"])
        // velumctl's status output is the whole file plus "fresh" and "ageSeconds".
        let status = keyPaths(try! StatusDocument.encoder().encode(VelumCtl.answer(.status, fresh)))
        #expect(status == Self.documentKeys.union(["fresh", "ageSeconds"]))
    }

    @Test func roundTripsWithDatesToTheMillisecond() throws {
        var d = Self.full
        d.written = now.addingTimeInterval(0.25)
        let back = try StatusDocument.decoder().decode(StatusDocument.self, from: data(d))
        #expect(back == d)
        #expect(String(decoding: data(d), as: UTF8.self).contains("\"written\" : \"2027-01-15T08:00:00.250Z\""))
    }
}

@Suite struct TheFile {
    func folder() -> URL { FileManager.default.temporaryDirectory.appending(path: "velum-tests-\(UUID().uuidString)") }

    @Test func writesAtomicallyForThisUserOnly() throws {
        let url = folder().appending(path: "status.json")
        try document(.pending(1)).write(to: url)
        var mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // Replacing a file someone made world-readable makes it 0600 again; no temporary file is left behind.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try document(.safe).write(to: url)
        mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["status.json"])
        #expect(StatusReading.read(url, now: now, isRunning: alive).lid == .safe)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@MainActor @Suite struct FromTheApp {
    /// Three services, five accounts, two of them Google accounts that came and went at run time.
    static func snapshot() -> Snapshot {
        var googleA = Fixture.evidence(GoogleDriveProvider.config(email: "alex.sample@example.com",
            root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-alex.sample@example.com")),
            report: GoogleDriveProvider.pausedReport(now: now))
        googleA.storage = StorageFigures(GoogleStorage(limit: 400_000_000_000, used: 186_000_000_000,
                                                      usedInDrive: 12_000_000_000, source: .googleSignIn, asOf: now))
        googleA.notes = ["214 GB free of 400 GB"]
        let googleB = Fixture.evidence(GoogleDriveProvider.config(email: "sam.sample@example.com",
            root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-sam.sample@example.com")),
            report: GoogleDriveProvider.pausedReport(now: now))
        var iCloud = Fixture.evidence(Fixture.iCloud(), report: Fixture.report(.ok, "Up to date", label: "iCloud status"))
        iCloud.storage = StorageFigures(iCloudFree: 0, asOf: now)
        var snapshot = Snapshot()
        snapshot.providers = [ProviderStatus(id: .oneDrive, clientRunning: true,
                                             compatibility: CompatibilityReport(provider: .oneDrive, version: "26.212.1029")),
                              ProviderStatus(id: .iCloud, clientRunning: nil, trouble: "Storage full"),
                              ProviderStatus(id: .googleDrive, clientRunning: true)]
        snapshot.providers[2].paused = true
        snapshot.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date"))),
                             Fixture.status(Fixture.evidence(Fixture.oneDrive("Business1", name: "Northwind Traders"),
                                                             report: Fixture.report(.ok, "Up to date"))),
                             Fixture.status(iCloud), Fixture.status(googleA), Fixture.status(googleB)]
        return snapshot
    }

    static func notInCloud() -> PendingList {
        let folder = "/Users/test/Library/CloudStorage/OneDrive-Personal"
        let files = [
            Velum.PendingFile(account: "Personal", path: "\(folder)/bad.txt", since: now.addingTimeInterval(-60), status: .failed("Too long.")),
            Velum.PendingFile(account: "Personal", path: "\(folder)/old.txt", since: now.addingTimeInterval(-700), status: .waiting),
            Velum.PendingFile(account: "Personal", path: "\(folder)/new.txt", since: now.addingTimeInterval(-20), status: .uploading),
        ]
        return PendingList(files: files, total: 4, perAccount: ["Personal": 4])
    }

    func document(_ snapshot: Snapshot? = nil) -> StatusDocument {
        var s = snapshot ?? Self.snapshot()
        s.stuck = PendingList(files: [], total: 2, perAccount: ["Personal": 2])
        return StatusFile.document(s, summary: "Can’t tell for iCloud Drive", state: .unknown, notInCloud: Self.notInCloud(),
                                   now: now, stuckAfter: 600)
    }

    @Test func servicesAndAccountsAreWhateverIsThere() {
        let d = document()
        #expect(d.services.map(\.id) == ["onedrive", "icloud", "googledrive"])
        #expect(d.accounts.map(\.key) == ["Personal", "Business1", "iCloudDrive",
                                          "googledrive:alex.sample@example.com", "googledrive:sam.sample@example.com"])
        #expect(d.accounts.filter { $0.service == "googledrive" }.count == 2)
        // Accounts come and go: one service with none left, or none at all, is still a valid file.
        var fewer = Self.snapshot()
        fewer.accounts.removeAll { $0.provider == .googleDrive }
        #expect(document(fewer).accounts.count == 3)
        #expect(StatusFile.document(Snapshot(), summary: "No cloud accounts found", state: .unknown, notInCloud: PendingList(),
                                    now: now).lid == .unknown("No cloud accounts found"))
    }

    @Test func perServiceFacts() {
        let d = document()
        #expect(d.services[0].appRunning == true && d.services[0].paused == nil)
        #expect(d.services[0].compatibility?.version == "26.212.1029")
        #expect(d.services[0].compatibility?.headline.hasPrefix("OneDrive 26.212") == true)
        #expect(d.services[1].appRunning == nil && d.services[1].trouble == "Storage full")
        #expect(d.services[2].paused == true)
    }

    @Test func perAccountFacts() {
        let d = document()
        let alex = d.accounts[3]
        #expect(alex.state == .paused && alex.headline == "Paused" && alex.age == "live")
        #expect(alex.notes == "214 GB free of 400 GB")
        #expect(alex.storage == Storage(limit: 400_000_000_000, used: 186_000_000_000, free: 214_000_000_000,
                                        usedByFiles: 12_000_000_000, full: false, source: .googleSignIn, asOf: now))
        #expect(d.accounts[2].storage == Storage(limit: nil, used: nil, free: 0, usedByFiles: nil, full: true, source: .iCloudQuota, asOf: now))
        #expect(d.accounts[0].storage == nil)
        #expect(d.accounts[0].source == "Nothing pending · OneDrive report, \(RelTime.clock(now.addingTimeInterval(-600)))")
        #expect(d.accounts[0].detail == "Nothing pending · OneDrive report 10 min ago")
        #expect(d.accounts[0].age == "10 min ago")
        #expect(d.accounts[0].uploads.stuck == 2 && d.accounts[1].uploads.stuck == 0)
    }

    @Test func pendingCarriesEveryFileAndMarksTheStuckOnes() {
        let p = document().pending
        #expect(p.total == 4 && p.stuck == 2 && p.stuckAfter == 600)
        #expect(p.files.map(\.name) == ["bad.txt", "old.txt", "new.txt"])
        #expect(p.files.map(\.stuck) == [true, true, false])
        #expect(p.files.map(\.status) == [.failing, .waiting, .uploading])
        #expect(p.files[0].reason == "Too long.")
    }

    @Test func everyLidVerdictMaps() {
        #expect(Lid(LidVerdict.safe) == .safe)
        #expect(Lid(LidVerdict.pending(2)) == .pending(2))
        #expect(Lid(LidVerdict.busy("A")) == .busy("A"))
        #expect(Lid(LidVerdict.failing(1)) == .failing(1))
        #expect(Lid(LidVerdict.notRunning("OneDrive")) == .notRunning("OneDrive"))
        #expect(Lid(LidVerdict.unknown("Why")) == .unknown("Why"))
        let all: [SyncState] = [.ok, .unknown, .syncing, .offline, .paused, .warning, .notRunning, .error]
        #expect(all.map { AccountState($0).rawValue } == ["ok", "unknown", "syncing", "offline", "paused", "warning", "notRunning", "error"])
    }

    @Test func theRunningAppsWriteIsWhatVelumctlReads() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "velum-tests-\(UUID().uuidString)/status.json")
        let store = Store()
        var snapshot = Self.snapshot()
        snapshot.accounts[0].uploadsPending = 1
        store.show(snapshot)
        let file = StatusFile(url: url)
        file.write(store, notInCloud: Self.notInCloud())
        file.flush()
        let read = StatusReading.read(url, isRunning: StatusReading.processExists)
        #expect(read.fresh)
        #expect(read.lid == Lid(store.lidVerdict))
        #expect(read.document?.app.pid == ProcessInfo.processInfo.processIdentifier)
        #expect(read.document?.summary == store.summary)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

@Suite struct TextOutput {
    @Test func lidIsOneLineLikeThePanel() {
        #expect(run("lid").stdout == "Safe to close the lid. Every change in the watched cloud folders is in the cloud.\n")
        #expect(run("lid", reading: interpreted(document(.pending(1)))).stdout == "Wait before closing the lid. 1 file still on the way up.\n")
        #expect(run("lid", reading: interpreted(document(.failing(2)))).stdout == "Not everything is in the cloud. 2 files can’t upload.\n")
        #expect(run("lid", reading: interpreted(document(.notRunning("Google Drive")))).stdout
                == "Not everything is in the cloud. Google Drive isn’t running, so new changes stay on this Mac.\n")
    }

    @MainActor @Test func statusShowsAHeadingPerServiceAndItsAccounts() {
        let d = FromTheApp().document()
        let text = run("status", reading: interpreted(d)).stdout
        #expect(text.hasPrefix("Can’t tell for iCloud Drive\n"))
        #expect(text.contains("\nOneDrive\n  Personal: Up to date\n"))
        #expect(text.contains("\niCloud · Storage full\n  iCloud Drive: Up to date\n"))
        #expect(text.contains("\nGoogle Drive\n  alex.sample@example.com: Paused\n    214 GB free of 400 GB\n"))
        #expect(text.contains("  sam.sample@example.com: Paused\n"))
        #expect(text.hasSuffix("  sam.sample@example.com: Paused\n    Google Drive is paused, live\n"))
    }

    @MainActor @Test func pendingListsFilesFailingFirst() {
        let text = run("pending", reading: interpreted(FromTheApp().document())).stdout
        #expect(text.contains("4 files aren’t in the cloud yet:"))
        #expect(text.contains("bad.txt\n    Personal · can’t upload: Too long · changed 1 min ago\n"))
        #expect(text.contains("old.txt\n    Personal · waiting · stuck · changed 11 min ago\n"))
        #expect(text.contains("new.txt\n    Personal · uploading · changed just now\n"))
        #expect(text.contains("…and 1 more."))
        #expect(run("pending").stdout == "Safe to close the lid. Every change in the watched cloud folders is in the cloud.\n\nNo files Velum tracks are waiting to upload.\n")
        // Live, the lid counted an upload macOS reported before the tracker had checked the file: say so, not "none".
        #expect(run("pending", reading: interpreted(document(.pending(1)))).stdout == "Wait before closing the lid. 1 file still on the way up."
                + "\n\nVelum can’t name it yet: macOS reported the upload before Velum checked the file.\n")
    }
}
