import Foundation

/// Made-up panels for `Velum --render-panel out.png --sample healthy|unknown|old|beta [--legend] [--dark]`, so the panel can be drawn and shared
/// without anyone's real accounts, emails or file names. Every row goes through the real status merge
/// (`Collector.status`), so a sample shows exactly what that evidence would show.
enum SampleData {
    static let names = ["healthy", "unknown", "old", "beta"]

    static func snapshot(_ name: String, now: Date = Date()) -> Snapshot? {
        guard names.contains(name) else { return nil }
        let personal = oneDrive("Personal", name: "Personal")
        let work = oneDrive("Business1", name: "Northwind Traders")
        let iCloud = iCloudDrive()
        let google = googleDrive("alex.sample@example.com")

        var covered = UploadSummary()
        covered.waiting = 0
        func report(_ label: String, minutesAgo: Double, every: TimeInterval?, _ state: SyncState = .ok,
                    _ headline: String = "Up to date") -> ProviderReport {
            ProviderReport(label: label, written: now.addingTimeInterval(-minutesAgo * 60), state: state, headline: headline,
                           every: every)
        }

        var personalEvidence = AccountEvidence(config: personal, name: personal.fallbackName)
        personalEvidence.report = report("OneDrive report", minutesAgo: 12, every: OneDriveProvider.reportEvery)
        personalEvidence.lastActivity = now.addingTimeInterval(-5 * 60)

        var workEvidence = AccountEvidence(config: work, name: work.fallbackName)
        workEvidence.report = report("OneDrive report", minutesAgo: 31, every: OneDriveProvider.reportEvery)
        workEvidence.lastActivity = now.addingTimeInterval(-40 * 60)

        var iCloudEvidence = AccountEvidence(config: iCloud, name: "iCloud Drive")
        iCloudEvidence.report = report("iCloud status", minutesAgo: 4, every: ICloudProvider.checkInterval)
        iCloudEvidence.notes = ["Desktop & Documents included", "214 GB free"]

        var googleEvidence = AccountEvidence(config: google, name: google.fallbackName)
        googleEvidence.report = GoogleDriveProvider.report(queued: 0, now: now)
        googleEvidence.notes = ["214 GB free of 400 GB"]
        googleEvidence.notesHelp = "Google storage, shared by Drive, Gmail and Photos"

        var gap = UploadSummary()
        gap.coverageGap = true

        var iCloudUploads = covered
        switch name {
        case "unknown":
            // Two accounts unknown at once: a OneDrive account with no report yet, and iCloud's first check.
            // The reasons come from the providers' own wording.
            workEvidence.report = nil
            workEvidence.unknownReason = OneDriveProvider.noReportReason(diag: nil, since: now.addingTimeInterval(-20 * 60), now: now)
            iCloudEvidence.report = nil
            iCloudEvidence.unknownReason = ICloudProvider.noStatusReason(lastCheck: nil, answered: nil, checking: true, next: nil)
        case "old":
            // A healthy OneDrive report gone old, an old "Paused" one, and a gap in Velum's own tracking.
            var old = report("OneDrive report", minutesAgo: 192, every: OneDriveProvider.reportEvery)
            old.reason = OneDriveProvider.reason(for: old, code: 0, now: now)
            workEvidence.report = old
            var paused = report("OneDrive report", minutesAgo: 140, every: OneDriveProvider.reportEvery, .paused, "Paused")
            paused.reason = OneDriveProvider.reason(for: paused, code: 65536, now: now)
            personalEvidence.report = paused
            iCloudUploads = gap
            iCloudUploads.coverageGapUntil = now.addingTimeInterval(9 * 60)
        default:
            break
        }

        var snapshot = Snapshot()
        snapshot.providers = [ProviderStatus(id: .oneDrive, clientRunning: true),
                              ProviderStatus(id: .iCloud, clientRunning: nil),
                              ProviderStatus(id: .googleDrive, clientRunning: true)]
        func status(_ e: AccountEvidence, _ u: UploadSummary) -> AccountStatus {
            Collector.status(e, transfer: nil, uploads: u, watchingUploads: true, now: now)
        }
        snapshot.accounts = [status(personalEvidence, covered), status(workEvidence, covered),
                             status(iCloudEvidence, iCloudUploads), status(googleEvidence, covered)]
        if name == "beta" {   // C3: the generic tier, one folder identified and idle, one unnamed and uploading
            let (generic, uploads) = betaFolders()
            snapshot.providers.append(ProviderStatus(id: .cloudStorage, clientRunning: nil))
            snapshot.accounts += zip(GenericProvider.accounts(generic), uploads).map { status($0, $1) }
        }
        snapshot.activity = [
            Activity(accountKey: personal.key, path: personal.folder.path + "/Budget 2026.xlsx", name: "Budget 2026.xlsx",
                     kind: 5, date: now.addingTimeInterval(-5 * 60), app: "Numbers"),
            Activity(accountKey: iCloud.key, path: "/Users/sample/Documents/Trip notes.md", name: "Trip notes.md",
                     kind: 5, date: now.addingTimeInterval(-18 * 60), app: nil),
            Activity(accountKey: work.key, path: work.folder.path + "/Plans/Q4 review.pptx", name: "Q4 review.pptx",
                     kind: 4, date: now.addingTimeInterval(-40 * 60), app: nil),
            Activity(accountKey: google.key, path: google.folder.path + "/Photos/Garden.heic", name: "Garden.heic",
                     kind: 5, date: now.addingTimeInterval(-65 * 60), app: nil),
        ]
        return snapshot
    }

    private static func oneDrive(_ key: String, name: String) -> AccountConfig {
        let folder = URL(fileURLWithPath: "/Users/sample/Library/CloudStorage/OneDrive-\(name)")
        return AccountConfig(key: key, provider: .oneDrive, folder: folder, watchRoots: [folder],
                             places: [NamedRoot(path: folder.path, name: folder.lastPathComponent, prefixed: false)],
                             fallbackName: name, webURL: URL(string: "https://onedrive.live.com/")!)
    }

    private static func iCloudDrive() -> AccountConfig {
        let root = URL(fileURLWithPath: "/Users/sample/Library/Mobile Documents/com~apple~CloudDocs")
        let documents = URL(fileURLWithPath: "/Users/sample/Documents")
        return AccountConfig(key: ICloudProvider.key, provider: .iCloud, folder: root, watchRoots: [root, documents],
                             places: [NamedRoot(path: root.path, name: "iCloud Drive", prefixed: false),
                                      NamedRoot(path: documents.path, name: "Documents", prefixed: true)],
                             fallbackName: "iCloud Drive", webURL: URL(string: "https://www.icloud.com/iclouddrive/")!,
                             keepsOwnHistory: false)
    }

    /// Made-up generic folders: "Dropbox", identified, idle; "AcmeSync-alex.sample@example.com", unnamed, uploading.
    private static func betaFolders() -> ([GenericProvider.Folder], [UploadSummary]) {
        let base = "/Users/sample/Library/CloudStorage/"
        let app = GenericProvider.ClientApp(name: "Dropbox", bundleID: "com.example.dropbox", extensionID: "com.example.dropbox.fileprovider")
        let dropbox = GenericProvider.folder(name: "Dropbox", root: URL(fileURLWithPath: base + "Dropbox"),
                                             extensionID: app.extensionID, app: app)
        let acme = GenericProvider.folder(name: "AcmeSync-alex.sample@example.com", root: URL(fileURLWithPath: base + "AcmeSync-alex.sample@example.com"),
                                          extensionID: nil, app: nil)
        var uploading = UploadSummary()
        uploading.uploading = 2
        return ([dropbox, acme], [UploadSummary(), uploading])
    }

    private static func googleDrive(_ email: String) -> AccountConfig {
        GoogleDriveProvider.config(email: email, root: URL(fileURLWithPath: "/Users/sample/Library/CloudStorage/GoogleDrive-\(email)"))
    }
}
