import AppKit

/// Google Drive's internals, checked every time Velum reads them (card A7). Used only from the collector's
/// serial queue, by `GoogleDriveProvider`:
/// - **folder names**: accounts are `GoogleDrive-<email>` folders. If none is found while Drive's own
///   `my-drive` links point at live folders, each linked folder still shows as an account;
/// - **live folders**: every live root Drive links to must be watched by a row, or the lid can't vouch;
/// - **account data**: each account's DriveFS folder, found through its `my-drive` link;
/// - **queue**: `metadata_sqlite_db`'s `operations` table. Unreadable for over 10 s (Fable's rule), the row
///   has no status and the lid can't vouch, since deletes and renames would go unseen;
/// - **storage record**: `properties` → `driveway_account`. It already fails safe (limit − used = remaining),
///   so it is only recorded: storage is optional and its absence can be legitimate;
/// - the `user-paused` file can't be checked (its absence is normal); DriveFS being there covers its place.
final class GoogleDriveCompatibility {
    /// How long a failed queue read may lean on the last good one.
    static let queueGrace: TimeInterval = 10
    /// A just-added account may not have its data folder linked yet.
    static let linkGrace: TimeInterval = 60

    private let cloudStorage: URL
    private let driveFS: URL
    /// Test seams: the installed Google Drive's version, and whether a folder is a live File Provider root.
    var readVersion: () -> String? = { ClientVersion.installed(bundleID: "com.google.drivefs") }
    var isLive: (URL) -> Bool? = isLiveCloudFolder

    private(set) var version: String?
    private var naming: InternalCheck?
    private var driveFSCheck: InternalCheck?
    private var data: [String: InternalCheck] = [:]
    private var queueShape: [String: InternalCheck] = [:]
    private var storage: [String: InternalCheck] = [:]
    private var firstSeen: [String: Date] = [:]
    private var lastGoodQueue: [String: (count: Int, at: Date)] = [:]
    private var queueRead: [String: Int?] = [:]          // this pass: what the provider got, or nil (unreadable)
    private var liveRoots: [URL] = []
    private let unwatched = UnwatchedRoots()
    private var logged: CompatibilityReport?

    init(cloudStorage: URL, driveFS: URL) {
        self.cloudStorage = cloudStorage
        self.driveFS = driveFS
    }

    private var client: String { CompatibilityReport(provider: .googleDrive, version: version).client }

    /// After each discovery (every minute, and on force): reads Drive's version, checks the folder names, each
    /// account's data folder, its queue's table and its storage record. Returns the accounts to show and their
    /// data folders: Drive's own, or the folders its links name when no `GoogleDrive-*` folder is found.
    func discovered(_ configs: [AccountConfig], dataFolders: [String: URL], now: Date) -> (configs: [AccountConfig], dataFolders: [String: URL]) {
        let installed = readVersion()
        if installed != version {
            queueShape = [:]
            storage = [:]
            lastGoodQueue = [:]
        }
        version = installed

        let linked = linkedRoots()
        var live: [String: URL] = [:]
        for root in linked + liveNamedRoots() where isLive(root) == true { live[root.standardizedFileURL.path] = root }
        liveRoots = live.keys.sorted().compactMap { live[$0] }
        var configs = configs
        var dataFolders = dataFolders
        let known = Set(configs.map { $0.watchRoots[0].standardizedFileURL.path })
        let strays = linked.filter { !known.contains($0.standardizedFileURL.path) && isLive($0) == true }
        naming = nil
        if configs.isEmpty, !strays.isEmpty, installed != nil {
            naming = InternalCheck(name: "folder names (GoogleDrive-<email>)", result: .changed,
                                   detail: "no GoogleDrive- folder, but Drive links to \(strays.map(\.lastPathComponent).joined(separator: ", "))",
                                   phrase: "folder names", note: CompatibilityText.googleNaming(client))
            configs = strays.map { GoogleDriveProvider.config(email: $0.lastPathComponent, root: $0) }
            dataFolders = GoogleDriveProvider.dataFolders(in: driveFS, for: configs)
        } else if !configs.isEmpty {
            naming = InternalCheck(name: "folder names (GoogleDrive-<email>)", result: .fine,
                                   detail: "\(configs.count) account\(configs.count == 1 ? "" : "s")")
        }
        guard !configs.isEmpty else { return (configs, dataFolders) }

        var isDir: ObjCBool = false
        let hasDriveFS = FileManager.default.fileExists(atPath: driveFS.path, isDirectory: &isDir) && isDir.boolValue
        let paused = FileManager.default.fileExists(atPath: driveFS.appending(path: "user-paused").path)
        driveFSCheck = InternalCheck(
            name: "Google Drive’s data folder (DriveFS)", result: hasDriveFS ? .fine : .changed,
            detail: hasDriveFS ? (paused ? "paused (user-paused file)" : "not paused") : "not found",
            guardsLid: true, phrase: "account data", note: CompatibilityText.googleData(client),
            lidReason: CompatibilityText.lidQueue)

        let keys = Set(configs.map(\.key))
        firstSeen = firstSeen.filter { keys.contains($0.key) }
        var newData: [String: InternalCheck] = [:]
        for config in configs {
            let seen = firstSeen[config.key] ?? now
            firstSeen[config.key] = seen
            let name = config.fallbackName
            guard let folder = dataFolders[config.key] else {
                let young = now.timeIntervalSince(seen) < Self.linkGrace
                newData[config.key] = InternalCheck(
                    name: "account data (my-drive link)", accountKey: config.key, accountName: name,
                    result: !hasDriveFS || young ? .missing : .changed,
                    detail: !hasDriveFS ? "no DriveFS folder" : young ? "new account, its data isn’t linked yet" : "no DriveFS folder links to it",
                    guardsLid: true, phrase: "account data", note: CompatibilityText.googleData(client),
                    lidReason: CompatibilityText.lidQueue)
                queueShape[config.key] = nil
                storage[config.key] = nil
                continue
            }
            newData[config.key] = InternalCheck(name: "account data (my-drive link)", accountKey: config.key, accountName: name,
                                                result: .fine, detail: "linked")   // never the folder's name: it's Drive's account ID
            let db = folder.appending(path: "metadata_sqlite_db").path

            if let (result, detail) = SQLiteSchema.check(SQLiteSchema.columns(of: "operations", in: db), table: "operations", required: []) {
                queueShape[config.key] = InternalCheck(
                    name: "queue (operations table)", accountKey: config.key, accountName: name, result: result, detail: detail,
                    guardsLid: true, phrase: "queue", note: CompatibilityText.googleQueue(client), lidReason: CompatibilityText.lidQueue)
            }
            if let check = Self.storageCheck(db: db, key: config.key, name: name) ?? storage[config.key] {
                storage[config.key] = check
            }
        }
        data = newData
        return (configs, dataFolders)
    }

    /// The queue length to use for an account this pass: a fresh reading, or for up to 10 s after a failed
    /// read the last good one; nil once the queue has been unreadable for longer.
    func queue(_ key: String, read: Int?, now: Date) -> Int? {
        if let read {
            lastGoodQueue[key] = (read, now)
            queueRead[key] = read
            return read
        }
        queueRead[key] = .some(nil)
        guard let last = lastGoodQueue[key], now.timeIntervalSince(last.at) <= Self.queueGrace else { return nil }
        return last.count
    }

    /// Before the evidence leaves the provider: the reasons on the rows, and the report.
    func apply(_ evidence: inout ProviderEvidence, now: Date) {
        var report = CompatibilityReport(provider: .googleDrive, version: version)
        if let naming { report.checks.append(naming) }
        if let check = unwatched.check(live: liveRoots, watched: evidence.accounts.map(\.config), provider: .googleDrive, now: now) {
            report.checks.append(check)
        }
        if let driveFSCheck { report.checks.append(driveFSCheck) }
        for account in evidence.accounts {
            let key = account.config.key
            if let check = data[key] { report.checks.append(check) }
            if var shape = queueShape[key] {
                // Read this pass and nothing usable came back, without the table having changed: not a change.
                if shape.result == .fine, let read = queueRead[key] {
                    if let count = read {
                        shape.detail = count == 0 ? "empty" : "\(count) queued"
                    } else if account.report == nil {
                        shape.result = .unavailable
                        shape.detail = "can’t be read right now"
                        shape.note = CompatibilityText.googleQueueNow
                    } else {
                        shape.detail = "a read failed, using the last one for up to \(Int(Self.queueGrace)) s"
                    }
                }
                report.checks.append(shape)
            }
            if let check = storage[key] { report.checks.append(check) }
        }
        queueRead = [:]
        report.record(into: &evidence, logged: &logged)
    }

    /// The storage record's shape. Never alerts and adds no reason line (Fable: storage is optional, and the
    /// cache can legitimately lack it; the sign-in fills in then). nil for a passing hiccup.
    static func storageCheck(db: String, key: String, name: String) -> InternalCheck? {
        var check = InternalCheck(name: "storage record (driveway_account)", accountKey: key, accountName: name,
                                  result: .fine, quiet: true, phrase: "storage record")
        guard let (result, detail) = SQLiteSchema.check(SQLiteSchema.columns(of: "properties", in: db), table: "properties",
                                                        required: ["property", "value"]) else { return nil }
        check.result = result
        check.detail = detail
        guard result == .fine else { return check }
        guard let blob = GoogleDriveProvider.readProperty("driveway_account", db: db) else {
            check.result = .missing
            check.detail = "no cached account record (the optional sign-in can fill in storage)"
            return check
        }
        if GoogleDriveProvider.parseStorage(blob, asOf: Date()) == nil {
            check.result = .changed
            check.detail = "the record doesn’t add up as storage, so none is shown"
        } else {
            check.detail = "limit − used = remaining holds"
        }
        return check
    }

    /// The CloudStorage folders Drive's `my-drive` links point into (absolute or relative links).
    func linkedRoots() -> [URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: driveFS.path) else { return [] }
        let base = cloudStorage.standardizedFileURL.path + "/"
        var roots = Set<String>()
        for name in names where !name.isEmpty && name.allSatisfy(\.isNumber) {
            let folder = driveFS.appending(path: name, directoryHint: .isDirectory)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: folder.appending(path: "my-drive").path) else { continue }
            let path = URL(fileURLWithPath: target, relativeTo: folder).standardizedFileURL.path
            guard path.hasPrefix(base), let top = path.dropFirst(base.count).split(separator: "/").first else { continue }
            roots.insert(base + top)
        }
        return roots.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func liveNamedRoots() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage.path) else { return [] }
        return names.filter { $0.hasPrefix(GoogleDriveProvider.folderPrefix) }
            .map { cloudStorage.appending(path: $0, directoryHint: .isDirectory) }
    }
}
