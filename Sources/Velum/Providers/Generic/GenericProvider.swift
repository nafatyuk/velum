import AppKit

/// Card C3, the generic tier (beta): every live File Provider folder under `~/Library/CloudStorage` that no
/// deep adapter claims (Dropbox, Box, Proton Drive, Nextcloud…), at basic fidelity. Velum reads nothing of the
/// client's own: only what macOS keeps for every File Provider folder alike (FSEvents, the per-file upload
/// flags, transfer progress), which `UploadTracker` and `TransferMonitor` collect for any watched folder. So:
/// - files waiting, uploading, failing (with macOS's reason) and downloading show, as for every service;
/// - there is no report, so a row is never "Up to date": with nothing moving it says it can't tell;
/// - the lid line never says "safe" on the strength of these folders (`Snapshot.lidVerdict`), because no
///   client here has had its flags confirmed on a real Mac (the adapter guide's live checklist, step 1);
/// - no "not running" claim: Velum doesn't know which process serves a folder, so `clientRunning` is nil.
///
/// Verified on macOS 27.3 (November 2026), on a Mac whose only CloudStorage clients are OneDrive and Google
/// Drive (no generic client was installed; P2's and P3's testers check real ones):
/// - `isLiveCloudFolder` answers a clear yes for the live roots and "no value" for two folders left behind by
///   removed OneDrive accounts (named with a date in parentheses), which therefore never show;
/// - every live root carries the extended attribute `com.apple.file-provider-domain-id`, "<the File Provider
///   extension's bundle ID>/<the domain's ID>"; the leftovers carry none. The extension is found inside the
///   app that syncs the folder (`Contents/PlugIns/*.appex`), which names the client for certain. Where that
///   fails, the row is named from the folder alone and says so.
final class GenericProvider: SyncProvider, @unchecked Sendable {
    let id = ProviderID.cloudStorage
    static let keyPrefix = "cloudstorage:"
    /// The extended attribute macOS sets on a live File Provider root.
    static let domainAttribute = "com.apple.file-provider-domain-id"

    /// The app that syncs a folder, found through the File Provider extension inside it.
    struct ClientApp: Equatable {
        let name: String            // "Dropbox", as the app names itself
        let bundleID: String        // the app's
        let extensionID: String     // the File Provider extension's, from the folder's domain
    }

    /// One live folder, as discovered.
    struct Folder: Equatable {
        let config: AccountConfig
        /// The client's name: the identified app's, or the folder's own spelling ("ProtonDrive") when not.
        let client: String
        /// The folder name's account part ("Personal", an address), nil when it has none.
        let account: String?
        /// nil: Velum can't tell which app syncs this folder.
        let app: ClientApp?
        /// The extension's bundle ID from the folder's domain, even when no installed app contains it.
        let extensionID: String?
    }

    private let cloudStorage: URL
    private(set) var folders: [Folder] = []
    private var lastDiscovery = Date.distantPast

    /// Test seams: whether a folder is a live File Provider root, its domain ("<extension ID>/<domain ID>"),
    /// and the installed app containing an extension.
    var isLive: (URL) -> Bool? = isLiveCloudFolder
    var domainOf: (URL) -> String? = GenericProvider.fileProviderDomain
    var appFor: (String) -> ClientApp? = GenericProvider.app(containing:)
    /// ••• → Show Other Cloud Folders; on by default (decided overnight, November 13; the owner's to reverse).
    var shown: () -> Bool = { GenericProvider.isShown }
    /// Test-only (card C3's cross-check): take the folders the deep adapters claim too.
    var claimsNothing = false

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }

    static let shownKey = "showOtherCloudFolders"
    static var isShown: Bool {
        get { UserDefaults.standard.object(forKey: shownKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shownKey) }
    }

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        guard claimsNothing || shown() else {
            folders = []
            lastDiscovery = .distantPast
            return ProviderEvidence()
        }
        if force || now.timeIntervalSince(lastDiscovery) > 60 {
            folders = discover(known: Set(folders.map(\.config.key)))
            lastDiscovery = now
        }
        guard !folders.isEmpty else { return ProviderEvidence() }        // rule 5: present only with a live folder
        // nil: Velum can't tell which process serves a folder, so it never says "not running".
        var evidence = ProviderEvidence(present: true, clientRunning: nil)
        evidence.accounts = Self.accounts(folders)
        return evidence
    }

    /// One row's evidence per folder. `running` stays true: no "not running" claim. No report: with nothing
    /// moving, the row can't tell (rule 1), and says why.
    static func accounts(_ folders: [Folder]) -> [AccountEvidence] {
        zip(folders, rowNames(folders)).map { folder, name in
            var account = AccountEvidence(config: folder.config, name: name)
            account.unknownHeadline = GenericText.headline
            account.unknownReason = GenericText.unknownReason(folder)
            account.notes = [GenericText.note(folder, named: name)]
            account.notesHelp = GenericText.help(folder)
            return account
        }
    }

    // MARK: Discovery

    /// Every folder under CloudStorage that is a live File Provider root (a clear yes only) and that no deep
    /// adapter claims. On a passing hiccup (nil) a folder already shown stays; a new one waits.
    func discover(known: Set<String>) -> [Folder] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cloudStorage.path) else { return [] }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { name -> Folder? in
            guard !name.hasPrefix(".") else { return nil }
            let root = cloudStorage.appending(path: name, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            let extensionID = domainOf(root).flatMap(Self.extensionID(fromDomain:))
            if !claimsNothing, ProviderID.allCases.contains(where: { $0.claims(folder: name, extensionID: extensionID) }) {
                return nil
            }
            switch isLive(root) {                                   // rule 4: only a clear yes makes a new row
            case true?: break
            case nil: guard known.contains(Self.keyPrefix + name) else { return nil }
            case false?: return nil
            }
            return Self.folder(name: name, root: root, extensionID: extensionID, app: extensionID.flatMap(appFor))
        }
    }

    static func folder(name: String, root: URL, extensionID: String?, app: ClientApp?) -> Folder {
        let (spelled, account) = parts(of: name)
        let client = app?.name ?? spelled
        let config = AccountConfig(
            key: keyPrefix + name, provider: .cloudStorage, folder: root, watchRoots: [root],
            places: [NamedRoot(path: root.path, name: client, prefixed: false)],
            fallbackName: client, webURL: nil, keepsOwnHistory: false)
        return Folder(config: config, client: client, account: account, app: app, extensionID: extensionID)
    }

    /// macOS names these folders "<the app's name without spaces>-<the account>": "Dropbox-Personal" →
    /// ("Dropbox", "Personal"), "Box-Box" → ("Box", nil), "Dropbox" → ("Dropbox", nil).
    static func parts(of folder: String) -> (client: String, account: String?) {
        guard let dash = folder.firstIndex(of: "-"), dash != folder.startIndex else { return (folder, nil) }
        let client = String(folder[..<dash])
        let account = String(folder[folder.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
        return (client, account.isEmpty || account == client ? nil : account)
    }

    /// The rows' names: the client's, and "Dropbox (Work)" only where two rows would share one, so alerts and
    /// the summary can tell them apart. An address shows only its part before the @ ("Proton Drive (someone)"),
    /// unless that clashes too; a clash with no account part falls back to the folder's name (Fable's rulings).
    static func rowNames(_ folders: [Folder]) -> [String] {
        func count(_ values: [String]) -> [String: Int] { Dictionary(values.map { ($0.lowercased(), 1) }, uniquingKeysWith: +) }
        func short(_ account: String) -> String {
            guard let at = account.firstIndex(of: "@"), at != account.startIndex else { return account }
            return String(account[..<at])
        }
        let clients = count(folders.map(\.client))
        let labels = folders.map { $0.account.map(short) ?? "" }
        let clashes = count(zip(folders, labels).map { $0.client + "|" + $1 })
        return zip(folders, labels).map { folder, label in
            guard clients[folder.client.lowercased(), default: 0] > 1 else { return folder.client }
            guard let account = folder.account else { return folder.config.folder.lastPathComponent }
            let clash = clashes[(folder.client + "|" + label).lowercased(), default: 0] > 1
            return "\(folder.client) (\(clash ? account : label))"
        }
    }

    /// Which app syncs the folder at `root`, read afresh (for `Velum --dump` and the diagnostics report).
    static func identify(_ root: URL) -> (extensionID: String?, app: ClientApp?) {
        let ext = fileProviderDomain(root).flatMap(extensionID(fromDomain:))
        return (ext, ext.flatMap(app(containing:)))
    }

    // MARK: Which app

    /// The folder's File Provider domain, "<extension bundle ID>/<domain ID>", from the extended attribute
    /// macOS sets on a live root; nil when there is none (leftover folders, plain folders). The domain's ID is
    /// the client's own (Google Drive's is its numeric account ID): never shown or logged.
    static func fileProviderDomain(_ url: URL) -> String? {
        let size = getxattr(url.path, domainAttribute, nil, 0, 0, 0)
        guard size > 0, size <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, domainAttribute, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        let text = String(decoding: buffer.prefix(read), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return text.isEmpty ? nil : text
    }

    /// "com.example.sync.fileprovider/domain-1" → "com.example.sync.fileprovider"; nil unless it looks like a bundle ID.
    static func extensionID(fromDomain domain: String) -> String? {
        let id = domain.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }), !id.contains(where: \.isWhitespace) else { return nil }
        return id
    }

    /// The installed app that contains the extension `extensionID`. An extension's bundle ID starts with its
    /// app's, so the candidates are its shorter prefixes ("com.example.sync.fileprovider" → "com.example.sync");
    /// one counts only if that app really ships an extension with exactly this ID. Never a guess by name.
    static func app(containing extensionID: String) -> ClientApp? {
        var parts = extensionID.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidate),
                  extensionIDs(in: url).contains(extensionID) else { continue }
            return ClientApp(name: displayName(of: url), bundleID: candidate, extensionID: extensionID)
        }
        return nil
    }

    /// The bundle IDs of the extensions an app ships (`Contents/PlugIns` and `Contents/Extensions`).
    static func extensionIDs(in app: URL) -> Set<String> {
        var ids = Set<String>()
        for folder in ["Contents/PlugIns", "Contents/Extensions"] {
            let dir = app.appending(path: folder, directoryHint: .isDirectory)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".appex") {
                if let id = infoPlist(dir.appending(path: name))?["CFBundleIdentifier"] as? String { ids.insert(id) }
            }
        }
        return ids
    }

    static func displayName(of app: URL) -> String {
        let info = infoPlist(app)
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = (info?[key] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        }
        return app.deletingPathExtension().lastPathComponent
    }

    private static func infoPlist(_ bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appending(path: "Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}

extension ProviderID {
    /// The generic tier (card C3): labelled beta wherever it shows, never "Up to date", never a "safe" lid.
    var isBeta: Bool { self == .cloudStorage }

    /// Whether this service's own adapter owns a folder under `~/Library/CloudStorage`, by the folder's name or
    /// by the File Provider extension behind it (so a renamed folder stays with its adapter). The generic tier
    /// leaves these alone, so nothing shows twice. A new deep adapter adds its claim here.
    func claims(folder name: String, extensionID: String?) -> Bool {
        let ext = extensionID ?? ""
        switch self {
        case .oneDrive: return name.hasPrefix("OneDrive-") || (!ext.isEmpty && ext.hasPrefix(oneDriveBundleID))
        case .googleDrive: return name.hasPrefix(GoogleDriveProvider.folderPrefix) || (!ext.isEmpty && ext.hasPrefix("com.google.drivefs"))
        case .iCloud: return ext.hasPrefix("com.apple.CloudDocs")    // iCloud Drive lives elsewhere; never shown twice should it appear
        case .cloudStorage: return false
        }
    }
}

/// Every sentence the generic tier shows, in one place. Wording by the Codex and Fable consult (November 13,
/// 2026; Fable ruled where the two differed).
enum GenericText {
    /// The idle row's headline: "Can’t tell", with no "yet", since nothing here would end the doubt.
    static let headline = "Can’t tell"

    /// The notes line's mark for a folder whose app Velum couldn't identify.
    static let appUnknown = "app unknown"

    /// Under "Can’t tell": what Velum sees, and what it can't.
    static func unknownReason(_ folder: GenericProvider.Folder) -> String {
        "Velum sees only macOS’s file flags here, not \(folder.app.map { $0.name + "’s" } ?? "the sync app’s") own status."
    }

    /// The merge's follow-up on an idle row whose tracking has no gaps: the source says it, not Velum.
    static let nothingWaiting = "macOS shows nothing waiting to upload."

    /// The notes line: "Beta", "Beta · Personal", "Beta · app unknown · someone@example.com". The account part
    /// is left out when the row's name already carries it.
    static func note(_ folder: GenericProvider.Folder, named name: String) -> String {
        var parts = ["Beta"]
        if folder.app == nil { parts.append(appUnknown) }
        if let account = folder.account, name == folder.client { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    /// The notes line's hover text.
    static func help(_ folder: GenericProvider.Folder) -> String {
        let support = folder.app.map { "Support for \($0.name) is untested." } ?? "Support for this folder’s app is untested."
        let status = folder.app.map { "Velum can’t read \($0.name)’s own status" } ?? "Velum can’t read the app’s own status"
        var text = "Velum shows the file activity macOS reports for this folder. \(support) \(status), including whether it’s paused or signed out. The lid line won’t say “Safe” while this folder is shown."
        if folder.app == nil { text += " " + unnamed }
        return text
    }

    static let unnamed = "Velum can’t tell which app syncs this folder. The name comes from the folder."

    /// The lid's reason, under "Can’t vouch for every change" (a clause: the panel adds the period). `clients`
    /// are the shown folders' client names; `unnamed`, whether any is only the folder's spelling.
    static func lid(clients: [String], unnamed: Bool, folders: Int) -> String {
        var names: [String] = []
        for client in clients where !names.contains(client) { names.append(client) }
        if unnamed || names.isEmpty || names.count > 2 {
            return folders == 1 ? "Velum hasn’t been tested with this cloud folder’s app (beta)"
                                : "Velum hasn’t been tested with \(folders) cloud folders’ apps (beta)"
        }
        return "Velum hasn’t been tested with \(names.joined(separator: " or ")) (beta)"
    }

    /// The lid's reason for the generic rows among `accounts`; nil when there are none.
    static func lid(_ accounts: [AccountStatus]) -> String? {
        let beta = accounts.filter(\.provider.isBeta)
        guard !beta.isEmpty else { return nil }
        let unnamed = beta.contains { $0.notes.hasPrefix("Beta · " + appUnknown) }
        return lid(clients: beta.map(\.config.fallbackName), unnamed: unnamed, folders: beta.count)
    }

    /// The legend's "Sources and age" line for the tier.
    static let legend = "Other cloud folders (beta): macOS’s live file flags and transfer progress, untested with each app. Their rows never say “Up to date”, and the lid line won’t say “Safe” while one is shown."

    /// `Velum --dump`'s service line.
    static func dumpService(_ folders: Int) -> String {
        "Other Cloud Folders (beta): \(folders == 1 ? "1 folder" : "\(folders) folders") · macOS’s file flags and transfer progress only · the lid can’t say safe"
    }

    /// `Velum --dump` and the diagnostics report: which app syncs a folder, and how Velum knows. Never the
    /// domain's own ID, which is the client's (Google Drive's is the account's number).
    static func dumpLine(_ found: (extensionID: String?, app: GenericProvider.ClientApp?)) -> String {
        if let app = found.app {
            return "beta: app \(app.name) (\(app.bundleID)), identified through this folder’s File Provider extension \(app.extensionID)"
        }
        let why = found.extensionID.map { " (its File Provider extension, \($0), isn’t inside an installed app)" } ?? " (the folder names no File Provider extension)"
        return "beta: Velum can’t tell which app syncs this folder; the name comes from the folder" + why
    }
}
