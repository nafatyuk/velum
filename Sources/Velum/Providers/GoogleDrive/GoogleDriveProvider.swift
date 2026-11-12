import AppKit
import SQLite3

/// Google Drive for desktop as a provider. Verified on macOS 27.3 with Drive 133 (November 2026):
/// - Each signed-in account streams through Apple's File Provider into
///   `~/Library/CloudStorage/GoogleDrive-<email>` (My Drive, Shared drives, …). File Provider's per-file
///   flags are real there, so uploads are tracked exactly like OneDrive's and iCloud's: a probe file read
///   "uploaded" about 25 s after it was written.
/// - Accounts are discovered from those folders on every pass, so any number of accounts can come and go;
///   a folder whose File Provider domain is gone (signed out, app removed) no longer reads as synced and
///   drops out. One app process (`com.google.drivefs`) serves every account.
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
        for config in configs {
            var account = AccountEvidence(config: config, name: config.fallbackName)
            account.running = running
            if running {
                // Drive's queue, when readable, decides; if a future Drive changes it, the per-file flags still
                // stand and the source line says only that Drive is running.
                let queued = dataFolders[config.key].flatMap { queueLength(config.key, folder: $0) }
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
