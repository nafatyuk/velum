import AppKit
import SQLite3

/// Storage for one Google account, shared by Drive, Gmail and Photos.
struct GoogleStorage: Equatable {
    var limit: Int64?          // nil = unlimited plan
    var used: Int64            // whole account
    var usedInDrive: Int64?
    var source: Source
    var asOf: Date
    enum Source: Equatable { case driveCache, googleSignIn }

    var free: Int64? { limit.map { max(0, $0 - used) } }
    /// Under 100 MB left (Fable's line: past that, new files won't fit).
    var isFull: Bool { free.map { $0 < 100 * 1_048_576 } ?? false }
    /// Past 90% and under 10 GB left, so a big plan with plenty of room stays quiet.
    var isAlmostFull: Bool {
        guard let limit, limit > 0, let free, !isFull else { return false }
        return Double(used) / Double(limit) >= 0.9 && free < 10 * 1_073_741_824
    }
}

/// Google Drive for desktop as a provider. Verified on macOS 27.3 with Drive 133 (November 2026):
/// - Each signed-in account streams through Apple's File Provider into
///   `~/Library/CloudStorage/GoogleDrive-<email>` (My Drive, Shared drives, …). File Provider's per-file
///   flags are real there, so uploads are tracked exactly like OneDrive's and iCloud's: a probe file read
///   "uploaded" about 25 s after it was written.
/// - Accounts are discovered from those folders on every pass, so any number of accounts can come and go;
///   a folder whose File Provider domain is gone (signed out, app removed) no longer reads as synced and
///   drops out. One app process (`com.google.drivefs`) serves every account.
/// - Drive also caches the account's storage there (the `driveway_account` property, a protobuf) and
///   marks a pause with an empty `user-paused` file at the top of DriveFS, so storage and "Paused" need no
///   sign-in. The optional Google sign-in (`signInStorage`) only fills in storage the cache lacks.
/// - Drive's own data (`~/Library/Application Support/Google/DriveFS/<id>/`, matched to an account through
///   the `my-drive` symlink inside it) has an `operations` table in `metadata_sqlite_db`: Drive's queue of
///   pending work, which held rows while a probe uploaded and was deleted and emptied afterwards. An empty
///   queue is the account-wide evidence for "Up to date". Its activity table stayed empty, so Velum records
///   the uploads it sees finish, as it does for iCloud.
final class GoogleDriveProvider: SyncProvider, @unchecked Sendable {
    let id = ProviderID.googleDrive
    static let folderPrefix = "GoogleDrive-"

    private let cloudStorage: URL
    private let driveFS: URL
    private var configs: [AccountConfig] = []
    private var dataFolders: [String: URL] = [:]        // account key → its DriveFS folder
    private var lastDiscovery = Date.distantPast
    private var queueCache: [String: (stamp: Date?, count: Int?)] = [:]
    private var busySince: [String: Date] = [:]
    private var loggedQueue: [String: String] = [:]        // for the debug log: the queue's last state per account
    private var storageCache: [String: (stamp: Date?, value: GoogleStorage?)] = [:]

    /// Storage from the optional Google sign-in, for accounts whose Drive cache has none. Set once at launch
    /// by the sign-in feature; called on the collector's queue every refresh: return cached figures, never block.
    nonisolated(unsafe) static var signInStorage: (_ email: String) -> GoogleStorage? = { _ in nil }

    /// A short note from the optional Google sign-in for this account ("Waiting for Google sign-in…",
    /// "Storage not shown · sign in again from the ••• menu"), or nil. Asked only when the Drive cache has no
    /// figures, like `signInStorage`. Same rules: collector's queue, never blocks.
    nonisolated(unsafe) static var signInNote: (_ email: String) -> String? = { _ in nil }

    /// The storage to show, and the sign-in's note: the Drive cache wins, and the sign-in is asked only when
    /// the cache has nothing.
    static func storage(cached: GoogleStorage?, email: String) -> (storage: GoogleStorage?, signInNote: String?) {
        guard cached == nil else { return (cached, nil) }
        return (signInStorage(email), signInNote(email))
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
        driveFS = home.appending(path: "Library/Application Support/Google/DriveFS", directoryHint: .isDirectory)
    }

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        if force || now.timeIntervalSince(lastDiscovery) > 60 {
            configs = discover(known: Set(configs.map(\.key)))
            dataFolders = Self.dataFolders(in: driveFS, for: configs)
            lastDiscovery = now
        }
        guard !configs.isEmpty, let bundleID = id.clientBundleID else { return ProviderEvidence() }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains { !$0.isTerminated }

        var evidence = ProviderEvidence(present: true, clientRunning: running)
        let paused = FileManager.default.fileExists(atPath: driveFS.appending(path: "user-paused").path)
        for config in configs {
            var account = AccountEvidence(config: config, name: config.fallbackName)
            account.running = running
            // The Drive cache wins; the optional sign-in is asked only when the cache has nothing, so with the
            // cache present it makes no request at all.
            let cached = dataFolders[config.key].flatMap { cachedStorage(config.key, folder: $0) }
            let (storage, signInNote) = Self.storage(cached: cached, email: config.fallbackName)
            if let storage {
                account.notes.append(Self.storageNote(storage))
                account.notesHelp = Self.storageHelp(storage)
                account.notesNeedAttention = storage.isFull || storage.isAlmostFull
                account.storageFull = storage.isFull
            }
            if let signInNote {
                account.notes.append(signInNote)
            }
            if running && paused {
                // Google Drive's own pause, for every account. Waiting files still show as "Paused, N waiting".
                account.report = Self.pausedReport(now: now)
            } else if running {
                // Drive's queue, when readable, decides; if a future Drive changes it, the per-file flags still
                // stand and the source line says only that Drive is running.
                let queued = dataFolders[config.key].flatMap { queueLength(config.key, folder: $0) }
                // Logged when the queue changes state (empty, busy, unreadable), not on every count.
                let queueState = queued.map { $0 == 0 ? "is empty" : "has work queued" } ?? "can't be read; trusting the per-file flags alone"
                if loggedQueue[config.key] != queueState {
                    debugLog("google", "\(config.fallbackName): Google Drive's queue \(queueState)\(queued.map { $0 > 0 ? " (\($0))" : "" } ?? "")")
                    loggedQueue[config.key] = queueState
                }
                if let queued, queued > 0 {
                    busySince[config.key] = busySince[config.key] ?? now
                } else {
                    busySince[config.key] = nil
                }
                account.workingSince = busySince[config.key]
                account.report = queued.map { Self.report(queued: $0, now: now) } ?? Self.runningReport(now: now)
            }
            evidence.accounts.append(account)
        }
        // Storage is optional information: it may mark the heading, never a row's state, the lid or the icon.
        let full = evidence.accounts.filter(\.storageFull).count
        if full > 0 { evidence.trouble = full == 1 ? "Storage full" : "\(full) accounts full" }
        return evidence
    }

    /// Drive's own queue as an account-wide status: empty means Drive has nothing left to do. Only reached
    /// when Velum sees nothing waiting or moving itself; with no queue to read, there is no report and the
    /// row says "No status yet", never "Up to date".
    static func report(queued: Int, now: Date) -> ProviderReport {
        queued == 0
            ? ProviderReport(label: "Google Drive's queue empty", written: now, state: .ok, headline: "Up to date", timed: false)
            : ProviderReport(label: "Google Drive's queue", written: now, state: .syncing, headline: "Syncing changes", timed: false)
    }

    static func pausedReport(now: Date) -> ProviderReport {
        ProviderReport(label: "Google Drive is paused", written: now, state: .paused, headline: "Paused", timed: false)
    }

    /// "214 GB free of 400 GB", like iCloud's line; "Almost full · 9 GB free of 400 GB"; "Storage full · shared
    /// with Gmail and Photos"; "186 GB used" on an unlimited plan.
    static func storageNote(_ storage: GoogleStorage) -> String {
        guard let limit = storage.limit, limit > 0, let free = storage.free else { return "\(size(storage.used)) used" }
        if storage.isFull { return "Storage full · shared with Gmail and Photos" }
        let line = "\(size(free)) free of \(size(limit))"
        return storage.isAlmostFull ? "Almost full · \(line)" : line
    }

    /// The hover text: what the figure covers, and how much of it is Drive's.
    static func storageHelp(_ storage: GoogleStorage) -> String {
        var parts = ["Google storage, shared by Drive, Gmail and Photos"]
        if let limit = storage.limit { parts.append("\(size(storage.used)) of \(size(limit)) used") }
        if let drive = storage.usedInDrive { parts.append("your files use \(size(drive))") }
        parts.append(storage.source == .driveCache ? "from Google Drive on this Mac" : "from your Google sign-in, \(RelTime.string(storage.asOf))")
        return parts.joined(separator: " · ")
    }

    /// Binary units, as Google labels them ("400 GB" is 400 × 2³⁰ bytes): one decimal under 10, else whole.
    static func size(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes), unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        if unit == 0 { return "\(bytes) bytes" }
        return value < 10 ? String(format: "%.1f %@", value, units[unit]) : "\(Int(value.rounded())) \(units[unit])"
    }

    /// No readable queue (a Drive version that changed its database): only "Drive is running" stands behind
    /// the live per-file evidence.
    static func runningReport(now: Date) -> ProviderReport {
        ProviderReport(label: "Google Drive running", written: now, state: .ok, headline: "Up to date", timed: false)
    }

    /// Each account's DriveFS folder, found through the `my-drive` symlink it keeps to the account's My Drive.
    static func dataFolders(in driveFS: URL, for configs: [AccountConfig]) -> [String: URL] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: driveFS.path) else { return [:] }
        var result: [String: URL] = [:]
        for name in names where !name.isEmpty && name.allSatisfy(\.isNumber) {
            let folder = driveFS.appending(path: name, directoryHint: .isDirectory)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: folder.appending(path: "my-drive").path) else { continue }
            let myDrive = URL(fileURLWithPath: target).standardizedFileURL.path
            if let config = configs.first(where: { myDrive.hasPrefix($0.watchRoots[0].standardizedFileURL.path + "/") }) {
                result[config.key] = folder
            }
        }
        return result
    }

    /// Rows in Drive's `operations` table, re-read only when the database changes. nil when unreadable.
    private func queueLength(_ key: String, folder: URL) -> Int? {
        let db = folder.appending(path: "metadata_sqlite_db").path
        let stamp = [db, db + "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
        if let cached = queueCache[key], cached.stamp == stamp { return cached.count }
        let count = Self.countOperations(db)
        queueCache[key] = (stamp, count)
        return count
    }

    /// The account's storage from Drive's own cache, re-read only when the database changes.
    private func cachedStorage(_ key: String, folder: URL) -> GoogleStorage? {
        let db = folder.appending(path: "metadata_sqlite_db").path
        let stamp = [db, db + "-wal"].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
        if let cached = storageCache[key], cached.stamp == stamp { return cached.value }
        let blob = Self.readProperty("driveway_account", db: db)
        let value = blob.flatMap { Self.parseStorage($0, asOf: Date()) }
        if blob != nil, value == nil {
            debugLog("google", "Google Drive's account record didn't parse as storage (format changed?); showing no storage")
        }
        storageCache[key] = (stamp, value)
        return value
    }

    /// The quota inside Drive's cached account record (`driveway_account`): message 2 → 3 → 1 holds
    /// 1 = limit, 3 = used by all services, 8 = remaining, 9 = used by the user. Undocumented, so the figures
    /// count only if limit − used = remaining (true on this Mac to the byte); any other shape gives nil and
    /// the row simply shows no storage.
    static func parseStorage(_ blob: Data, asOf: Date) -> GoogleStorage? {
        guard let account = Protobuf.message(blob, field: 2),
              let quotaWrapper = Protobuf.message(account, field: 3),
              let quota = Protobuf.message(quotaWrapper, field: 1) else { return nil }
        let fields = Protobuf.varints(quota)
        guard let used = fields[3].map(Int64.init) else { return nil }
        let limit = fields[1].map(Int64.init)
        if let limit, let remaining = fields[8].map(Int64.init) {
            guard limit - used == remaining else { return nil }
        } else if limit != nil {
            return nil      // a limit without the remaining figure to check it against
        }
        return GoogleStorage(limit: limit, used: used, usedInDrive: fields[9].map(Int64.init), source: .driveCache, asOf: asOf)
    }

    static func readProperty(_ name: String, db path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM properties WHERE property = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    static func countOperations(_ path: String) -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM operations", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Every live `GoogleDrive-<email>` folder, sorted by email. `known` accounts are kept through a moment
    /// when macOS can't be asked.
    func discover(known: Set<String> = []) -> [AccountConfig] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cloudStorage.path) else { return [] }
        return names.filter { $0.hasPrefix(Self.folderPrefix) }.sorted().compactMap { name in
            let root = cloudStorage.appending(path: name, directoryHint: .isDirectory)
            let email = String(name.dropFirst(Self.folderPrefix.count))
            guard !email.isEmpty else { return nil }
            let config = Self.config(email: email, root: root)
            switch isLiveCloudFolder(root) {
            case true?: return config
            case nil: return known.contains(config.key) ? config : nil
            case false?: return nil
            }
        }
    }

    static func config(email: String, root: URL) -> AccountConfig {
        let user = email.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@._-"))) ?? email
        func web(_ path: String) -> URL? { URL(string: "https://drive.google.com/\(path)?authuser=\(user)") }
        let myDrive = root.appending(path: "My Drive", directoryHint: .isDirectory)
        return AccountConfig(
            key: "googledrive:\(email)",
            provider: .googleDrive,
            folder: FileManager.default.fileExists(atPath: myDrive.path) ? myDrive : root,
            watchRoots: [root],
            places: [NamedRoot(path: root.appending(path: ".shortcut-targets-by-id").path, name: "a folder shared with you",
                               prefixed: false, flat: true),
                     NamedRoot(path: root.path, name: "Google Drive", prefixed: false)],
            fallbackName: email,
            webURL: web("drive/my-drive") ?? URL(string: "https://drive.google.com/")!,
            recycleBinURL: web("drive/trash"),
            storageURL: web("settings/storage"),
            keepsOwnHistory: false
        )
    }
}

/// Just enough protobuf reading for Drive's cached account record: varints and nested messages.
enum Protobuf {
    /// The first length-delimited field `field` in `data`, or nil.
    static func message(_ data: Data, field: Int) -> Data? {
        var found: Data?
        walk(data) { f, wire, value, bytes in
            if f == field, wire == 2, found == nil { found = bytes }
            _ = value
        }
        return found
    }

    /// Every varint field in `data` (top level only), last value wins.
    static func varints(_ data: Data) -> [Int: UInt64] {
        var result: [Int: UInt64] = [:]
        walk(data) { f, wire, value, _ in if wire == 0 { result[f] = value } }
        return result
    }

    private static func walk(_ data: Data, _ visit: (Int, Int, UInt64, Data?) -> Void) {
        let b = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var v: UInt64 = 0, shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return }
            let field = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0:
                guard let v = varint() else { return }
                visit(field, 0, v, nil)
            case 2:
                guard let n = varint(), n <= UInt64(b.count - i) else { return }
                visit(field, 2, 0, Data(b[i..<i + Int(n)]))
                i += Int(n)
            case 1: i += 8
            case 5: i += 4
            default: return
            }
        }
    }
}
