import Foundation

/// The sync services Velum knows. Raw values are stable: they key saved state and alerts.
enum ProviderID: String, CaseIterable, Codable {
    case oneDrive = "onedrive"
    case iCloud = "icloud"
    case googleDrive = "googledrive"

    var name: String {
        switch self {
        case .oneDrive: "OneDrive"
        case .iCloud: "iCloud"
        case .googleDrive: "Google Drive"
        }
    }

    /// What the row's menu calls the way back to deleted files.
    var deletedFilesLabel: String {
        switch self {
        case .oneDrive: "Recycle Bin"
        case .iCloud: "Recover Deleted Files…"
        case .googleDrive: "Trash"
        }
    }

    /// The service's own app, which Velum can start when it isn't running. nil: part of macOS.
    var clientBundleID: String? {
        switch self {
        case .oneDrive: oneDriveBundleID
        case .iCloud: nil
        case .googleDrive: "com.google.drivefs"
        }
    }
}

/// Is `url` the root of a live File Provider domain (a signed-in account's folder)? true or false when macOS
/// answers; a folder left behind by a removed account, or any plain folder, answers with no value, which
/// counts as false. nil only when macOS couldn't be asked at all, so callers can keep an account they
/// already know through a passing hiccup instead of letting it vanish.
func isLiveCloudFolder(_ url: URL) -> Bool? {
    do {
        return try url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem == true
    } catch {
        return nil
    }
}

/// One sync service. A provider finds its accounts and gathers what only it knows: its client's process,
/// the client's own status text, account-wide reports, its history. The evidence every File Provider folder
/// gives alike (FSEvents plus per-file upload flags in `UploadTracker`, transfer progress in
/// `TransferMonitor`) is collected for every account the same way, and `Collector.status` merges the two in
/// one fixed order for every provider.
protocol SyncProvider: AnyObject {
    var id: ProviderID { get }
    /// Called on the collector's serial queue for every refresh. Must not block for long.
    func gather(force: Bool, now: Date) -> ProviderEvidence
}

struct ProviderEvidence {
    /// Set up on this Mac at all. A provider that isn't shows nothing.
    var present = false
    /// Whether the client app runs; nil when there is no client to start or stop (iCloud is part of macOS).
    var clientRunning: Bool?
    var accounts: [AccountEvidence] = []
    var activity: [Activity] = []
    /// OneDrive's Accessibility path: trusted, and its icons' text found.
    var axTrusted = false
    var liveItemsFound = false
    /// A service-wide problem to show beside the service's name ("Storage full").
    var trouble: String?
    /// How the client's internals read against the tested versions (card A7).
    var compatibility: CompatibilityReport?
    /// The service's own pause switch, where it has one Velum reads (Google Drive's); for the status file (T1).
    var paused: Bool?
}

/// What a provider knows about one account, before the live File Provider evidence is merged in.
struct AccountEvidence {
    let config: AccountConfig
    var name: String
    var running = true
    var pid: pid_t?
    /// The client's own words for this account (OneDrive's icon text), when readable. Empty = found, no text.
    var exactStatus: String?
    var report: ProviderReport?
    var lastActivity: Date?
    /// Extra facts for the row ("Desktop & Documents included", "1.27 TB free").
    var notes: [String] = []
    /// Since when the provider's own queue has had work in it (Google Drive), for the stuck alert.
    var workingSince: Date?
    /// Hover text for the notes line, and whether it needs the eye (storage almost full or full).
    var notesHelp: String?
    var notesNeedAttention = false
    /// Out of storage (optional information: an alert and the heading, never the row's state).
    var storageFull = false
    /// Where the storage figure came from ("Google Drive’s cache on this Mac", "brctl quota"), or why there is
    /// none, for the diagnostics report (card S2). Never the figure itself.
    var storageSource: String?
    /// Why the provider has no status for this account, and what would end it ("Checking iCloud now. This
    /// takes about 15 seconds."). Shown under a row that ends up unknown with no report.
    var unknownReason: String?
    /// Why some of this account's evidence was dropped (card A7: "Can’t read OneDrive 27.0’s status report ·
    /// uploads are still tracked"). Also first in `notes`, so it shows today; card A4's reason line can use it.
    var compatibilityNote: String?
    /// The storage behind the notes line, as figures with their source, for the status file (T1).
    var storage: StorageFigures?
}

/// An account-wide status a provider writes or reports now and then (OneDrive's hourly diagnostics,
/// iCloud's `brctl status`), with when it was written.
struct ProviderReport: Equatable {
    var label: String           // "OneDrive report"
    var written: Date
    var state: SyncState        // .ok, .paused, .offline, .error or .unknown
    var headline: String
    /// false for live evidence that has no time of its own ("Google Drive's queue empty").
    var timed = true
    /// How often a fresh one comes (OneDrive's hourly report, Velum's 10-minute iCloud check). A timed report
    /// older than this plus `grace` is old: never green, never safe, and the row says so.
    var every: TimeInterval?
    /// Why this report leaves the status unknown or old, and what would end it, in the provider's words.
    var reason: String?

    static let grace: TimeInterval = 15 * 60

    var source: String { timed ? "\(label), \(RelTime.clock(written))" : label }

    func isOld(now: Date) -> Bool {
        guard timed, let every else { return false }
        return now.timeIntervalSince(written) > every + Self.grace
    }

    /// When the next one is due, for reason lines ("The next is due by 2:45 PM").
    var nextDue: Date? { every.map { written.addingTimeInterval($0) } }
}

/// A place inside an account, used to say where a file is: "In the top of OneDrive-Personal",
/// "In Coursework" (`prefixed` false), or "In Desktop", "In Documents/Taxes" (`prefixed` true).
struct NamedRoot: Equatable {
    let path: String
    let name: String
    let prefixed: Bool
    /// Say only "In <name>", however deep (folders named by IDs, like Google's shortcut targets).
    var flat = false
}

/// One synced account as Velum sees it, whichever service it belongs to.
struct AccountConfig: Equatable, Identifiable {
    let key: String                 // OneDrive's slot ("Personal", "Business1"), or "iCloudDrive"
    let provider: ProviderID
    let folder: URL                 // what Open in Finder opens
    let watchRoots: [URL]           // every folder whose changes count
    let places: [NamedRoot]         // every path that leads into the account (symlinks included)
    let fallbackName: String
    let webURL: URL
    var recycleBinURL: URL? = nil
    var storageURL: URL? = nil
    /// The service keeps its own history (OneDrive's activity list). Without one, Velum records the
    /// uploads it sees finish.
    var keepsOwnHistory = true

    var id: String { key }

    /// Where `path` sits in this account, in words; nil if it lies elsewhere.
    func location(of path: String) -> String? {
        for place in places {
            let relative: String
            if path == place.path {
                relative = ""
            } else if path.hasPrefix(place.path + "/") {
                relative = String(path.dropFirst(place.path.count + 1))
            } else {
                continue
            }
            let parent = (relative as NSString).deletingLastPathComponent
            if place.flat { return "In \(place.name)" }
            if place.prefixed { return parent.isEmpty ? "In \(place.name)" : "In \(place.name)/\(parent)" }
            return parent.isEmpty ? "In the top of \(place.name)" : "In \(parent)"
        }
        return nil
    }
}

/// One sync event in an account's history.
struct Activity: Identifiable, Equatable, Codable {
    let accountKey: String
    let path: String
    let name: String
    let kind: Int
    let date: Date
    let app: String?

    var id: String { accountKey + "|" + path }

    // Codes from OneDrive's UXDatabase history_list, checked against real files on this Mac:
    // 4 = downloaded, 5 = uploaded, 6 = deleted, 10 and 11 = moved away from this path,
    // 12 = restored by OneDrive (seen when a delete hit a file it was still downloading).
    // Uploads Velum records itself (iCloud) use 5.
    static let uploaded = 5

    var verb: String {
        switch kind {
        case 4: return "Downloaded"
        case 5: return "Uploaded"
        case 6: return "Deleted"
        case 10, 11: return "Moved"
        case 12: return "Restored"
        default: return "Synced"
        }
    }

    var isGone: Bool { kind == 6 || kind == 10 || kind == 11 }

    /// The app that opened the file, when OneDrive knows it (e.g. "Finder").
    var appName: String? {
        guard let app, !app.isEmpty, app != "fileproviderd", !app.hasPrefix("macbox_") else { return nil }
        return app
    }
}
