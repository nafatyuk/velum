import Foundation

/// The sync services Velum knows. Raw values are stable: they key saved state and alerts.
enum ProviderID: String, CaseIterable, Codable {
    case oneDrive = "onedrive"
    case iCloud = "icloud"

    var name: String {
        switch self {
        case .oneDrive: "OneDrive"
        case .iCloud: "iCloud"
        }
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
}

/// An account-wide status a provider writes or reports now and then (OneDrive's hourly diagnostics,
/// iCloud's `brctl status`), with when it was written.
struct ProviderReport: Equatable {
    var label: String           // "OneDrive report"
    var written: Date
    var state: SyncState        // .ok, .paused, .offline, .error or .unknown
    var headline: String

    var source: String { "\(label), \(RelTime.clock(written))" }
}

/// A place inside an account, used to say where a file is: "In the top of OneDrive-Personal",
/// "In Coursework" (`prefixed` false), or "In Desktop", "In Documents/Taxes" (`prefixed` true).
struct NamedRoot: Equatable {
    let path: String
    let name: String
    let prefixed: Bool
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
