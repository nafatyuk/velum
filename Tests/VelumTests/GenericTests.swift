import Foundation
import Testing
@testable import Velum

/// Card C3, the generic tier: made-up clients and folders only (`Acme`, `Example`), in a temporary folder tree
/// or under /Users/test. Nothing here touches the real ~/Library/CloudStorage.
@Suite struct GenericDiscovery {
    /// A fake home with these entries under Library/CloudStorage (folders, unless the name ends in ".txt").
    func home(_ entries: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "velum-c3-\(UUID().uuidString)")
        let cloud = home.appending(path: "Library/CloudStorage")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        for name in entries {
            if name.hasSuffix(".txt") || name.hasPrefix(".") {
                try Data("x".utf8).write(to: cloud.appending(path: name))
            } else {
                try FileManager.default.createDirectory(at: cloud.appending(path: name), withIntermediateDirectories: true)
            }
        }
        return home
    }

    static let acme = GenericProvider.ClientApp(name: "Acme Sync", bundleID: "com.example.acme", extensionID: "com.example.acme.fileprovider")

    /// A provider whose seams answer for the made-up folders: every folder is live except "Old…" ones (no value:
    /// false); domains by folder name; one installed app, Acme Sync.
    func provider(_ home: URL, live: @escaping (String) -> Bool? = { $0.hasPrefix("Old") ? false : true }) -> GenericProvider {
        let p = GenericProvider(home: home)
        p.isLive = { live($0.lastPathComponent) }
        p.domainOf = { url in
            switch url.lastPathComponent {
            case let n where n.hasPrefix("AcmeSync"): "com.example.acme.fileprovider/acme-domain-1"
            case let n where n.hasPrefix("Renamed"): "com.google.drivefs.fpext/gdrive-000"
            case let n where n.hasPrefix("Orphan"): "com.example.gone.fileprovider/x"
            default: nil
            }
        }
        p.appFor = { $0 == Self.acme.extensionID ? Self.acme : nil }
        p.shown = { true }
        return p
    }

    @Test func liveRootsShowLeftoversAndClaimedFoldersDont() throws {
        let home = try home(["OneDrive-Personal", "OneDrive-SharedLibraries-Example", "GoogleDrive-someone@example.com",
                             "Dropbox", "AcmeSync-someone@example.com-folder", "Box-Box", "Old-Client (1-2-26 3:04 PM)",
                             "RenamedDrive", ".DS_Store", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = provider(home)
        let evidence = p.gather(force: true, now: Fixture.now)
        #expect(evidence.present)
        #expect(evidence.clientRunning == nil)                  // never a "not running" claim
        #expect(p.folders.map { $0.config.folder.lastPathComponent } == ["AcmeSync-someone@example.com-folder", "Box-Box", "Dropbox"])
        #expect(evidence.accounts.map(\.name) == ["Acme Sync", "Box", "Dropbox"])
        #expect(evidence.accounts.allSatisfy { $0.running && $0.report == nil && $0.exactStatus == nil })
        #expect(evidence.accounts.map(\.config.key) == ["cloudstorage:AcmeSync-someone@example.com-folder", "cloudstorage:Box-Box", "cloudstorage:Dropbox"])
        #expect(evidence.accounts.allSatisfy { $0.config.provider == .cloudStorage && !$0.config.keepsOwnHistory && $0.config.webURL == nil })
    }

    @Test func plainFoldersAreNotLive() throws {
        // The real check, no seam: a plain folder answers "no value", which never counts as live.
        let home = try home(["Dropbox", "Example-Work"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = GenericProvider(home: home)
        p.shown = { true }
        #expect(p.discover(known: []).isEmpty)
        #expect(p.gather(force: true, now: Fixture.now).present == false)
        #expect(GenericProvider.fileProviderDomain(home.appending(path: "Library/CloudStorage/Dropbox")) == nil)
    }

    @Test func absentWithoutCloudStorage() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "velum-none-\(UUID().uuidString)")
        let p = GenericProvider(home: empty)
        p.shown = { true }
        p.isLive = { _ in true }
        #expect(p.gather(force: true, now: Fixture.now).present == false)
    }

    @Test func aHiccupKeepsKnownFoldersAndAddsNone() throws {
        let home = try home(["Dropbox", "Box-Box"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = provider(home, live: { _ in nil })
        #expect(p.discover(known: ["cloudstorage:Dropbox"]).map(\.config.key) == ["cloudstorage:Dropbox"])
        #expect(p.discover(known: []).isEmpty)
    }

    @Test func switchedOffShowsNothing() throws {
        let home = try home(["Dropbox"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = provider(home)
        #expect(p.gather(force: true, now: Fixture.now).present)
        p.shown = { false }
        #expect(p.gather(force: false, now: Fixture.now).present == false)
        #expect(p.folders.isEmpty)
    }

    @Test func crossCheckModeTakesClaimedFoldersToo() throws {
        let home = try home(["OneDrive-Personal", "GoogleDrive-someone@example.com", "Dropbox"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = provider(home)
        p.claimsNothing = true
        #expect(p.discover(known: []).map(\.client) == ["Dropbox", "GoogleDrive", "OneDrive"])
    }

    @Test func unidentifiedAppsSaySo() throws {
        let home = try home(["Orphan-Work", "Plain"])
        defer { try? FileManager.default.removeItem(at: home) }
        let p = provider(home)
        let accounts = p.gather(force: true, now: Fixture.now).accounts
        #expect(accounts.map(\.name) == ["Orphan", "Plain"])
        #expect(accounts.map { $0.notes.first } == ["Beta · app unknown · Work", "Beta · app unknown"])
        #expect(accounts[0].notesHelp?.hasSuffix(GenericText.unnamed) == true)
        #expect(accounts[0].unknownReason == "Velum sees only macOS’s file flags here, not the sync app’s own status.")
        #expect(p.folders[0].extensionID == "com.example.gone.fileprovider")
        #expect(GenericText.dumpLine((p.folders[0].extensionID, nil)).contains("isn’t inside an installed app"))
        #expect(GenericText.dumpLine((nil, nil)).contains("names no File Provider extension"))
        #expect(GenericText.dumpLine((Self.acme.extensionID, Self.acme))
                == "beta: app Acme Sync (com.example.acme), identified through this folder’s File Provider extension com.example.acme.fileprovider")
    }
}

@Suite struct GenericNaming {
    @Test func folderNamesSplitIntoClientAndAccount() {
        #expect(GenericProvider.parts(of: "Dropbox") == ("Dropbox", nil))
        #expect(GenericProvider.parts(of: "Dropbox-Personal") == ("Dropbox", "Personal"))
        #expect(GenericProvider.parts(of: "Box-Box") == ("Box", nil))
        #expect(GenericProvider.parts(of: "ProtonDrive-someone@example.com-folder") == ("ProtonDrive", "someone@example.com-folder"))
        #expect(GenericProvider.parts(of: "Example-") == ("Example", nil))
        #expect(GenericProvider.parts(of: "-odd") == ("-odd", nil))
    }

    func folder(_ name: String, app: String? = nil) -> GenericProvider.Folder {
        GenericProvider.folder(name: name, root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/\(name)"), extensionID: nil,
                               app: app.map { GenericProvider.ClientApp(name: $0, bundleID: "com.example.x", extensionID: "com.example.x.fp") })
    }

    @Test func clashingNamesTakeTheirAccount() {
        #expect(GenericProvider.rowNames([folder("Dropbox", app: "Dropbox"), folder("Example-Work")]) == ["Dropbox", "Example"])
        #expect(GenericProvider.rowNames([folder("Dropbox-Personal", app: "Dropbox"), folder("Dropbox-Work", app: "Dropbox")])
                == ["Dropbox (Personal)", "Dropbox (Work)"])
        // An address shows its part before the @, unless that clashes too.
        #expect(GenericProvider.rowNames([folder("Example-alex@example.com"), folder("Example-sam@example.org")])
                == ["Example (alex)", "Example (sam)"])
        #expect(GenericProvider.rowNames([folder("Example-alex@example.com"), folder("Example-alex@example.org")])
                == ["Example (alex@example.com)", "Example (alex@example.org)"])
        // No account part to tell them apart: the folder's own name.
        #expect(GenericProvider.rowNames([folder("Example"), folder("Example-Box")]) == ["Example", "Example (Box)"])
    }

    @Test func notesCarryBetaAndTheAccountOnce() {
        let f = folder("Dropbox-Personal", app: "Dropbox")
        #expect(GenericText.note(f, named: "Dropbox") == "Beta · Personal")
        #expect(GenericText.note(f, named: "Dropbox (Personal)") == "Beta")
        #expect(GenericText.note(folder("Dropbox", app: "Dropbox"), named: "Dropbox") == "Beta")
        #expect(GenericText.note(folder("Example-alex@example.com"), named: "Example") == "Beta · app unknown · alex@example.com")
        #expect(GenericText.help(f).hasPrefix("Velum shows the file activity macOS reports for this folder. Support for Dropbox is untested."))
        #expect(GenericText.help(f).contains("The lid line won’t say “Safe” while this folder is shown."))
    }

    @Test func domainsNameTheirExtension() {
        #expect(GenericProvider.extensionID(fromDomain: "com.example.sync.fileprovider/domain-1") == "com.example.sync.fileprovider")
        #expect(GenericProvider.extensionID(fromDomain: "com.example.sync") == "com.example.sync")
        #expect(GenericProvider.extensionID(fromDomain: "") == nil)
        #expect(GenericProvider.extensionID(fromDomain: "garbage") == nil)
        #expect(GenericProvider.extensionID(fromDomain: "com..example/x") == nil)
        #expect(GenericProvider.extensionID(fromDomain: "com.example sync/x") == nil)
    }

    @Test func theDomainAttributeIsRead() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-c3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(GenericProvider.fileProviderDomain(dir) == nil)
        let value = Array("com.example.sync.fileprovider/domain-1".utf8)
        // Only where this Mac lets a test set the attribute; the reader is the point.
        if setxattr(dir.path, GenericProvider.domainAttribute, value, value.count, 0, 0) == 0 {
            #expect(GenericProvider.fileProviderDomain(dir) == "com.example.sync.fileprovider/domain-1")
        }
    }

    @Test func appsAreFoundByTheExtensionTheyShip() throws {
        let app = FileManager.default.temporaryDirectory.appending(path: "velum-c3-\(UUID().uuidString)/Example Sync.app")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let appex = app.appending(path: "Contents/PlugIns/Sync.appex/Contents")
        try FileManager.default.createDirectory(at: appex, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.sync.fileprovider"], format: .xml, options: 0)
            .write(to: appex.appending(path: "Info.plist"))
        #expect(GenericProvider.extensionIDs(in: app) == ["com.example.sync.fileprovider"])
        #expect(GenericProvider.displayName(of: app) == "Example Sync")           // no Info.plist: the bundle's name
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Example"], format: .xml, options: 0)
            .write(to: app.appending(path: "Contents/Info.plist"))
        #expect(GenericProvider.displayName(of: app) == "Example")
        // An extension no installed app ships: not identified, never guessed from its name.
        #expect(GenericProvider.app(containing: "com.example.velum-test-none.fileprovider") == nil)
    }

    @Test func deepAdaptersKeepTheirFolders() {
        func claimed(_ name: String, _ ext: String? = nil) -> Bool {
            ProviderID.allCases.contains { $0.claims(folder: name, extensionID: ext) }
        }
        #expect(claimed("OneDrive-Personal"))
        #expect(claimed("OneDrive-SharedLibraries-Example"))
        #expect(claimed("GoogleDrive-someone@example.com"))
        #expect(claimed("Renamed", "com.google.drivefs.fpext"))
        #expect(claimed("Renamed", "com.microsoft.OneDrive.FileProvider"))
        #expect(claimed("Renamed", "com.microsoft.OneDrive-mac.FileProvider"))
        #expect(claimed("Renamed", "com.apple.CloudDocs.iCloudDriveFileProvider"))
        #expect(!claimed("Dropbox", "com.example.dropbox.fileprovider"))
        #expect(!claimed("Dropbox"))
        #expect(ProviderID.cloudStorage.rawValue == "cloudstorage")
        #expect(ProviderID.cloudStorage.clientBundleID == nil)
        #expect(ProviderID.cloudStorage.name == "Other Cloud Folders")
    }
}

@Suite struct GenericEvidence {
    func account(_ name: String, app: String? = "Dropbox") -> AccountEvidence {
        let folder = GenericProvider.folder(name: name, root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/\(name)"), extensionID: nil,
                                            app: app.map { GenericProvider.ClientApp(name: $0, bundleID: "com.example.x", extensionID: "com.example.x.fp") })
        return GenericProvider.accounts([folder])[0]
    }

    func uploads(waiting: Int = 0, uploading: Int = 0, failed: Int = 0, gap: Bool = false) -> UploadSummary {
        var u = UploadSummary()
        u.waiting = waiting
        u.uploading = uploading
        u.failed = Array(repeating: "a.txt: The disk is full.", count: failed)
        u.coverageGap = gap
        return u
    }

    @Test func idleIsNeverUpToDate() {
        let s = Fixture.status(account("Dropbox"), uploads: uploads())
        #expect(s.state == .unknown)
        #expect(s.headline == "Can’t tell")
        #expect(s.reason == "Velum sees only macOS’s file flags here, not Dropbox’s own status. macOS shows nothing waiting to upload.")
        #expect(s.notes == "Beta")
        #expect(s.uploadsCovered)
        // Not watched yet: no "nothing waiting" at all, and the shared not-watching line.
        let fresh = Fixture.status(account("Dropbox"), uploads: nil, watching: false)
        #expect(fresh.state == .unknown)
        #expect(fresh.reason?.contains("nothing waiting") == false)
        #expect(fresh.reason?.hasSuffix(Reasons.notWatchingYet) == true)
    }

    @Test func liveWorkShowsAsForEveryService() {
        #expect(Fixture.status(account("Dropbox"), uploads: uploads(waiting: 1)).headline == "Waiting to upload 1 file")
        #expect(Fixture.status(account("Dropbox"), uploads: uploads(uploading: 2)).headline == "Uploading 2 files")
        let failing = Fixture.status(account("Dropbox"), uploads: uploads(failed: 1))
        #expect(failing.state == .error)
        #expect(failing.headline == "1 file can't upload")
        #expect(failing.detail.contains("The disk is full."))
        let down = Fixture.status(account("Dropbox"), transfer: TransferInfo(downloadingFiles: 3), uploads: uploads())
        #expect(down.headline == "Downloading 3 files")
    }

    @Test func otherServicesKeepTheirWords() {
        let s = Fixture.status(Fixture.evidence(Fixture.oneDrive()), uploads: UploadSummary())
        #expect(s.headline == "Can’t tell yet")
        #expect(GenericText.nothingWaiting != Reasons.nothingWaiting)
    }
}

@Suite struct GenericLid {
    func generic(_ name: String, app: String? = "Dropbox", pending: Int = 0, failed: Int = 0) -> AccountStatus {
        let folder = GenericProvider.folder(name: name, root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/\(name)"), extensionID: nil,
                                            app: app.map { GenericProvider.ClientApp(name: $0, bundleID: "com.example.x", extensionID: "com.example.x.fp") })
        var u = UploadSummary()
        u.waiting = pending
        u.failed = Array(repeating: "a.txt: no", count: failed)
        return Fixture.status(GenericProvider.accounts([folder])[0], uploads: u)
    }

    func healthyOneDrive() -> AccountStatus {
        Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date")), uploads: UploadSummary())
    }

    func snapshot(_ accounts: [AccountStatus]) -> Snapshot {
        var s = Snapshot()
        s.accounts = accounts
        s.providers = [ProviderStatus(id: .oneDrive, clientRunning: true), ProviderStatus(id: .cloudStorage, clientRunning: nil)]
        return s
    }

    @Test func betaFoldersNeverMakeItSafe() {
        #expect(snapshot([healthyOneDrive()]).lidVerdict == .safe)
        #expect(snapshot([healthyOneDrive(), generic("Dropbox")]).lidVerdict == .unknown("Velum hasn’t been tested with Dropbox (beta)"))
        #expect(snapshot([healthyOneDrive(), generic("Dropbox"), generic("Box-Box", app: "Box")]).lidVerdict
                == .unknown("Velum hasn’t been tested with Dropbox or Box (beta)"))
        #expect(snapshot([generic("Dropbox-A"), generic("Dropbox-B")]).lidVerdict == .unknown("Velum hasn’t been tested with Dropbox (beta)"))
        #expect(snapshot([generic("Dropbox"), generic("Box-Box", app: "Box"), generic("Example-1", app: "Example")]).lidVerdict
                == .unknown("Velum hasn’t been tested with 3 cloud folders’ apps (beta)"))
        #expect(snapshot([generic("Acme", app: nil)]).lidVerdict == .unknown("Velum hasn’t been tested with this cloud folder’s app (beta)"))
        #expect(snapshot([generic("Dropbox"), generic("Acme", app: nil)]).lidVerdict == .unknown("Velum hasn’t been tested with 2 cloud folders’ apps (beta)"))
    }

    @Test func betaWorkStillCounts() {
        #expect(snapshot([healthyOneDrive(), generic("Dropbox", pending: 2)]).lidVerdict == .pending(2))
        #expect(snapshot([healthyOneDrive(), generic("Dropbox", failed: 1)]).lidVerdict == .failing(1))
    }
}

@Suite struct GenericReporting {
    @Test func onlyTheAccountPartIsPersonal() {
        let folder = GenericProvider.folder(name: "Example-alex@example.com", root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/Example-alex@example.com"),
                                            extensionID: nil, app: nil)
        let status = Fixture.status(GenericProvider.accounts([folder])[0])
        #expect(DiagnosticsReport.names(of: status) == ["alex@example.com"])
    }

    @Test func theLegendExplainsTheTier() {
        let lines = LegendView.sourceLines(for: [.oneDrive, .cloudStorage])
        #expect(lines.last == GenericText.legend)
        #expect(lines.first?.hasSuffix("The lid line trusts only live evidence, never a periodic report.") == true)
        #expect(LegendView.notesLines(for: [.oneDrive, .cloudStorage]).first
                == "Recent: OneDrive’s own history. For other cloud folders, only uploads Velum saw finish while it was running.")
    }

    @Test func theSamplePanelShowsTheTier() throws {
        let s = try #require(SampleData.snapshot("beta", now: Fixture.now))
        let beta = s.accounts.filter(\.provider.isBeta)
        #expect(beta.map(\.name) == ["Dropbox", "AcmeSync"])
        #expect(beta.map(\.headline) == ["Can’t tell", "Uploading 2 files"])
        #expect(s.lidVerdict == .pending(2))
    }
}
