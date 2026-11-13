import AppKit

/// OneDrive's internals, checked every time Velum reads them (card A7). Used only from the collector's serial
/// queue, by `OneDriveProvider`:
/// - **settings**: the `.ini` files' `libraryScope` lines, which list the accounts. If they list none while
///   live `OneDrive-*` folders exist, each folder still shows as an account Velum can only watch;
/// - **status report**: each account's `SyncDiagnostics.log` and its `SyncProgressState` code;
/// - **activity list**: each account's `UXDatabase.db` `history_list` columns, item types and times;
/// - **processes**: one per account, matched by the settings files each holds open;
/// - **live folders**: every live `OneDrive-*` root must be watched by a row, or the lid can't vouch.
/// Read-only, like everything Velum does to OneDrive.
final class OneDriveCompatibility {
    /// `SyncProgressState` codes seen on tested versions (community-documented; Microsoft publishes none).
    static let knownCodes: Set<Int> = [0, 16777216, 65536, 8194, 1854]
    static let historyColumns = ["FilePath", "FileName", "ItemType", "LastUpdatedTimeUTC", "HydratingExe"]
    /// `history_list` item types seen on tested versions (see `Activity`).
    static let knownItemTypes: Set<Int> = [4, 5, 6, 10, 11, 12]
    /// Accounts found from their folder alone, when OneDrive's settings list none.
    static let folderKeyPrefix = "onedrive-folder:"
    /// A just-launched OneDrive (as after an update) may not hold its settings files open yet.
    static let processGrace: TimeInterval = 120

    private let cloudStorage: URL
    private let settingsRoot: URL
    private let logsRoot: URL
    /// Test seams: the installed OneDrive's version, and whether a folder is a live File Provider root.
    var readVersion: () -> String? = { ClientVersion.installed(bundleID: oneDriveBundleID) }
    var isLive: (URL) -> Bool? = isLiveCloudFolder

    private(set) var version: String?
    private var settings: InternalCheck?
    private var history: [String: InternalCheck] = [:]
    private var diagnostics: [String: (stamp: Date?, check: InternalCheck)] = [:]
    private var unmappedSince: Date?
    private var liveRoots: [URL] = []
    private let unwatched = UnwatchedRoots()
    private var logged: CompatibilityReport?

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        settingsRoot = home.appending(path: "Library/Application Support/OneDrive/settings", directoryHint: .isDirectory)
        logsRoot = home.appending(path: "Library/Logs/OneDrive", directoryHint: .isDirectory)
    }

    /// After each discovery (every minute, and on force): reads OneDrive's version, checks the settings and each
    /// account's activity database. Returns the accounts to show: OneDrive's own, or each live folder as an
    /// account when the settings no longer list any.
    func discovered(_ configs: [AccountConfig], now: Date) -> [AccountConfig] {
        let installed = readVersion()
        if installed != version {
            // A new OneDrive: check everything again, not only what has changed on disk since.
            diagnostics = [:]
            history = [:]
            unmappedSince = nil
        }
        version = installed

        var checked: [String: InternalCheck] = [:]
        for config in configs {
            let read = SQLiteSchema.columns(of: "history_list", in: settingsRoot.appending(path: "\(config.key)/UXDatabase.db").path)
            var check = InternalCheck(name: "activity list (UXDatabase.db)", accountKey: config.key, accountName: config.fallbackName,
                                      result: .missing, detail: "no activity database yet", phrase: "activity list")
            if read != .noFile {
                guard let (result, detail) = SQLiteSchema.check(read, table: "history_list", required: Self.historyColumns) else {
                    if let previous = history[config.key] { checked[config.key] = previous }
                    continue
                }
                check.result = result
                check.detail = detail
            }
            if check.result == .changed { check.note = CompatibilityText.oneDriveActivity(client) }
            checked[config.key] = check
        }
        history = checked

        liveRoots = liveFolders()
        let known = Set(configs.map { $0.folder.standardizedFileURL.path })
        let strays = liveRoots.filter { !known.contains($0.standardizedFileURL.path) }
        if configs.isEmpty {
            // Signed out of everything, or not installed: nothing to show. Only an installed OneDrive whose
            // settings exist but name none of its live folders counts as changed settings.
            guard !strays.isEmpty, installed != nil, FileManager.default.fileExists(atPath: settingsRoot.path) else {
                settings = nil
                return []
            }
            // Every live folder becomes a row, so the lid still covers them all.
            settings = InternalCheck(name: "settings (libraryScope lines)", result: .changed,
                                     detail: "no account found, but \(strays.count) live OneDrive folder\(strays.count == 1 ? "" : "s")",
                                     phrase: "settings", note: CompatibilityText.oneDriveSettings(client))
            return strays.map(Self.folderConfig)
        }
        settings = InternalCheck(name: "settings (libraryScope lines)", result: .fine,
                                 detail: "\(configs.count) account\(configs.count == 1 ? "" : "s")")
        return configs
    }

    /// Before the evidence leaves the provider: drops what no longer reads, adds the reasons, records the report.
    func apply(_ evidence: inout ProviderEvidence, mappingUnknown: Bool, now: Date) {
        var report = CompatibilityReport(provider: .oneDrive, version: version)
        if let settings { report.checks.append(settings) }
        let foundFromFolders = settings?.result == .changed

        if let check = unwatched.check(live: liveRoots, watched: evidence.accounts.map(\.config), provider: .oneDrive, now: now) {
            report.checks.append(check)
        }
        // Unmatched processes don't stop the lid (it rests on per-file flags, which hold either way): the rows
        // keep their status and say Velum can't tell. No alert.
        if evidence.clientRunning == true, !foundFromFolders {
            unmappedSince = mappingUnknown ? (unmappedSince ?? now) : nil
            let lasting = unmappedSince.map { now.timeIntervalSince($0) >= Self.processGrace } ?? false
            report.checks.append(InternalCheck(
                name: "processes (matched by open settings files)", result: lasting ? .unavailable : .fine,
                detail: !mappingUnknown ? "each matched to its accounts"
                    : lasting ? "none holds an account’s settings open" : "not matched yet (OneDrive just started)",
                note: CompatibilityText.oneDriveProcesses))
        } else {
            unmappedSince = nil
        }

        var activity: [Activity] = []
        for i in evidence.accounts.indices {
            let key = evidence.accounts[i].config.key
            let name = evidence.accounts[i].name
            if key.hasPrefix(Self.folderKeyPrefix) {
                // No settings, so no process to match: running when OneDrive is.
                evidence.accounts[i].running = evidence.clientRunning == true
                evidence.accounts[i].pid = nil
                continue
            }
            if var check = diagnosticsCheck(key) {
                check.accountName = name
                report.checks.append(check)
            }
            var rows = evidence.activity.filter { $0.accountKey == key }
            if var check = history[key] {
                check.accountName = name
                report.checks.append(check)
                if check.result == .changed { rows = [] }
            }
            let screened = Self.screen(rows, now: now)
            if var check = screened.check {
                check.accountKey = key
                check.accountName = name
                if check.result == .changed { check.note = CompatibilityText.oneDriveActivity(client) }
                report.checks.append(check)
            }
            evidence.accounts[i].lastActivity = screened.kept.map(\.date).max()
            activity += screened.kept
        }
        evidence.activity = activity
        report.record(into: &evidence, logged: &logged)
    }

    private var client: String { CompatibilityReport(provider: .oneDrive, version: version).client }

    /// The account's status report, re-read only when the file changes. nil for a passing read failure.
    private func diagnosticsCheck(_ key: String) -> InternalCheck? {
        let path = logsRoot.appending(path: "\(key)/SyncDiagnostics.log").path
        let stamp = OneDriveFiles.modificationDate(path)
        if let cached = diagnostics[key], cached.stamp == stamp { return cached.check }
        let read = stamp == nil ? nil : OneDriveFiles.diagnostics(at: path)
        guard let (result, detail) = Self.diagnosticsResult(read, exists: stamp != nil) else { return diagnostics[key]?.check }
        var check = InternalCheck(name: "status report (SyncDiagnostics.log)", accountKey: key, result: result, detail: detail,
                                  phrase: "status report")
        if result == .changed { check.note = CompatibilityText.oneDriveReport(client) }
        if result == .unrecognized { check.note = CompatibilityText.oneDriveCode }
        diagnostics[key] = (stamp, check)
        return check
    }

    /// What a status report says about its own shape. nil: it exists but couldn't be read this time.
    static func diagnosticsResult(_ diag: Diagnostics?, exists: Bool) -> (InternalCheck.Result, String)? {
        guard exists else { return (.missing, "no report yet (OneDrive writes one about every hour)") }
        guard let diag else { return nil }
        if diag.isVerification { return (.fine, "a verification pass this time, with no status in it") }
        guard let code = diag.progressState else { return (.changed, "no SyncProgressState line") }
        return knownCodes.contains(code) ? (.fine, "code \(code)") : (.unrecognized, "unknown code \(code)")
    }

    /// Activity entries Velum can show: known item types with believable times. Anything else is left out
    /// (never shown as "Synced") and recorded. Times that don't read as dates mean the list changed shape;
    /// an unknown item type is more likely old and rare, so it gets no reason line and no alert.
    static func screen(_ rows: [Activity], now: Date) -> (kept: [Activity], check: InternalCheck?) {
        let earliest = Date(timeIntervalSince1970: 1_420_070_400)     // 2015: OneDrive for Mac's history starts later
        let latest = now.addingTimeInterval(2 * 86_400)
        let badTimes = rows.filter { $0.date < earliest || $0.date > latest }
        let strange = rows.filter { !knownItemTypes.contains($0.kind) }
        let kept = rows.filter { knownItemTypes.contains($0.kind) && $0.date >= earliest && $0.date <= latest }
        guard !rows.isEmpty else { return (kept, nil) }
        var check = InternalCheck(name: "activity entries", result: .fine, detail: "\(rows.count) read", phrase: "activity list")
        if !badTimes.isEmpty {
            check.result = .changed
            check.detail = "\(badTimes.count) of \(rows.count) times don’t read as dates"
        } else if !strange.isEmpty {
            let kinds = Set(strange.map(\.kind)).sorted().map(String.init).joined(separator: ", ")
            check.result = .unrecognized
            check.detail = "\(strange.count) of \(rows.count) of a kind Velum doesn’t know (type \(kinds)), left out of Recent"
        }
        return (kept, check)
    }

    /// Every live `OneDrive-*` File Provider root in CloudStorage, shared libraries included; dated leftovers
    /// from removed accounts aren't live.
    func liveFolders() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) else { return [] }
        return names.filter { $0.hasPrefix("OneDrive-") }.sorted()
            .map { cloudStorage.appending(path: $0, directoryHint: .isDirectory) }
            .filter { isLive($0) == true }
    }

    /// A live OneDrive folder as an account Velum can only watch: per-file upload tracking works; there is no
    /// report, process or activity list to read.
    static func folderConfig(_ folder: URL) -> AccountConfig {
        let name = folder.lastPathComponent
        return AccountConfig(
            key: folderKeyPrefix + name,
            provider: .oneDrive,
            folder: folder,
            watchRoots: [folder],
            places: [NamedRoot(path: folder.path, name: name, prefixed: false)],
            fallbackName: OneDriveFiles.fallbackName(kind: name == "OneDrive-Personal" ? .personal : .business, folder: folder),
            webURL: URL(string: "https://onedrive.live.com/")!,
            keepsOwnHistory: false
        )
    }
}
