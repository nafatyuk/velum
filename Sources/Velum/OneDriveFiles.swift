import AppKit
import Darwin
import SQLite3

let oneDriveBundleID = "com.microsoft.OneDrive"

enum AccountKind: String {
    case personal, business
}

/// One OneDrive account as configured on this Mac, read from OneDrive's own settings files.
struct AccountConfig: Equatable, Identifiable {
    let key: String             // OneDrive's slot name: "Personal", "Business1", "Business2", ...
    let kind: AccountKind
    let folder: URL             // ~/Library/CloudStorage/OneDrive-<Name>
    let aliases: [String]       // every path that points at the folder (e.g. the ~/OneDrive symlink)
    let siteURL: URL?           // the account's web root, from OneDrive's library settings
    let fallbackName: String

    var id: String { key }

    var webURL: URL {
        if kind == .business, let site = siteURL { return site.appending(path: "_layouts/15/onedrive.aspx") }
        return URL(string: "https://onedrive.live.com/")!
    }

    var recycleBinURL: URL? {
        guard kind == .business, let site = siteURL else { return nil }
        return site.appending(path: "_layouts/15/RecycleBin.aspx")
    }

    var storageURL: URL? {
        if kind == .business { return siteURL?.appending(path: "_layouts/15/storman.aspx") }
        return URL(string: "https://onedrive.live.com/?v=managestorage")
    }

    /// `path` relative to this account's folder, or nil if it lies elsewhere.
    func relativePath(of path: String) -> String? {
        for root in aliases {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return nil
    }
}

/// The hourly report OneDrive writes to ~/Library/Logs/OneDrive/<slot>/SyncDiagnostics.log.
struct Diagnostics: Equatable {
    var written: Date
    var progressState: Int?
    var pid: pid_t?
    var filesToUpload = 0
    var filesToDownload = 0
    var files = 0
    var folders = 0

    var pendingFiles: Int { filesToUpload + filesToDownload }
}

/// One row of OneDrive's activity history (the list its own menu bar panel shows).
struct Activity: Identifiable, Equatable {
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

/// Read-only access to the files OneDrive keeps on disk. Nothing here writes to OneDrive.
enum OneDriveFiles {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let settingsRoot = home.appending(path: "Library/Application Support/OneDrive/settings")
    static let logsRoot = home.appending(path: "Library/Logs/OneDrive")

    // MARK: Accounts

    static func discoverAccounts() -> [AccountConfig] {
        let fm = FileManager.default
        guard let slots = try? fm.contentsOfDirectory(atPath: settingsRoot.path) else { return [] }
        let links = homeSymlinks()
        var accounts: [AccountConfig] = []

        for key in slots where key == "Personal" || key.hasPrefix("Business") {
            let dir = settingsRoot.appending(path: key)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }

            var library: (path: String, site: String?)?
            for file in files.sorted() where file.hasSuffix(".ini") {
                guard let text = readText(dir.appending(path: file)) else { continue }
                let scopes = text.components(separatedBy: .newlines).filter { $0.hasPrefix("libraryScope = ") }
                guard let line = scopes.first(where: { $0.contains("\"MySite\"") }) ?? scopes.first else { continue }
                let quoted = quotedStrings(in: line)
                guard let path = quoted.first(where: { $0.hasPrefix("~/") || $0.hasPrefix("/") }) else { continue }
                library = (path, quoted.first(where: { $0.hasPrefix("https://") }))
                break
            }
            guard let library else { continue }

            // Signed-out accounts leave their settings behind but their folder is renamed, so skip those.
            let folderPath = (library.path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let folder = URL(fileURLWithPath: folderPath, isDirectory: true)
            let kind: AccountKind = key == "Personal" ? .personal : .business
            accounts.append(AccountConfig(
                key: key,
                kind: kind,
                folder: folder,
                aliases: [folderPath] + links.filter { $0.value == folderPath }.map(\.key).sorted(),
                siteURL: library.site.flatMap(URL.init(string:)),
                fallbackName: fallbackName(kind: kind, folder: folder)
            ))
        }
        // Personal first, then work/school accounts in OneDrive's own order.
        return accounts.sorted { ($0.kind == .personal ? "0" : "1") + $0.key < ($1.kind == .personal ? "0" : "1") + $1.key }
    }

    static func fallbackName(kind: AccountKind, folder: URL) -> String {
        if kind == .personal { return "Personal" }
        var name = folder.lastPathComponent
        if name.hasPrefix("OneDrive-") { name.removeFirst("OneDrive-".count) }
        var spaced = ""
        var previous: Character?
        for ch in name {
            if let p = previous, ch.isUppercase, p.isLowercase { spaced.append(" ") }
            spaced.append(ch)
            previous = ch
        }
        return spaced
    }

    // MARK: Hourly diagnostics

    static func diagnosticsPath(_ key: String) -> String {
        logsRoot.appending(path: "\(key)/SyncDiagnostics.log").path
    }

    static func diagnostics(at path: String) -> Diagnostics? {
        guard let written = modificationDate(path), let text = readText(URL(fileURLWithPath: path)) else { return nil }
        var d = Diagnostics(written: written)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SyncProgressState:") {
                d.progressState = Int(line.dropFirst("SyncProgressState:".count).trimmingCharacters(in: .whitespaces))
                continue
            }
            let parts = line.components(separatedBy: " = ")
            guard parts.count == 2 else { continue }
            let value = parts[1]
            switch parts[0] {
            case "FilesToUpload": d.filesToUpload = Int(value) ?? 0
            case "FilesToDownload": d.filesToDownload = Int(value) ?? 0
            case "files": d.files = Int(value) ?? 0
            case "folders": d.folders = Int(value) ?? 0
            case "pid": d.pid = pid_t(value)
            case "syncProgressState": if d.progressState == nil { d.progressState = Int(value) }
            default: break
            }
        }
        return d
    }

    // MARK: Activity history

    static func activityDatabase(_ key: String) -> String {
        settingsRoot.appending(path: "\(key)/UXDatabase.db").path
    }

    /// Changes whenever OneDrive writes to its history database (main file or its journal).
    static func activityStamp(_ key: String) -> Date? {
        let db = activityDatabase(key)
        return [db, db + "-wal", db + "-journal"].compactMap(modificationDate).max()
    }

    static func activity(_ key: String, limit: Int = 30) -> [Activity] {
        let path = activityDatabase(key)
        guard FileManager.default.fileExists(atPath: path) else { return [] }

        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let sql = """
            SELECT FilePath, FileName, ItemType, LastUpdatedTimeUTC, HydratingExe
            FROM history_list ORDER BY LastUpdatedTimeUTC DESC LIMIT \(limit)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var rows: [Activity] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(stmt, column).map { String(cString: $0) }
            }
            guard let filePath = text(0) else { continue }
            rows.append(Activity(
                accountKey: key,
                path: filePath,
                name: text(1) ?? (filePath as NSString).lastPathComponent,
                kind: Int(sqlite3_column_int(stmt, 2)),
                date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 3))),
                app: text(4)
            ))
        }
        return rows
    }

    // MARK: Which OneDrive process serves which account

    /// OneDrive runs one process per account; each keeps that account's settings databases open.
    static func accountKeys(openedBy pid: pid_t) -> Set<String> {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 32)
        let used = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return [] }

        var keys = Set<String>()
        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard let range = path.range(of: "/OneDrive/settings/") else { continue }
            let rest = path[range.upperBound...]
            guard let slot = rest.split(separator: "/").first, rest.contains("/") else { continue }
            if slot == "Personal" || slot.hasPrefix("Business") { keys.insert(String(slot)) }
        }
        return keys
    }

    // MARK: Helpers

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func quotedStrings(in line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote = false
        for ch in line {
            if ch == "\"" {
                if inQuote { result.append(current); current = "" }
                inQuote.toggle()
            } else if inQuote {
                current.append(ch)
            }
        }
        return result
    }

    /// Symlinks directly inside the home folder, mapped to where they point (e.g. ~/OneDrive).
    static func homeSymlinks() -> [String: String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home.path) else { return [:] }
        var links: [String: String] = [:]
        for name in names {
            let path = home.appending(path: name).path
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
            let absolute = destination.hasPrefix("/") ? destination : home.appending(path: destination).path
            links[path] = (absolute as NSString).standardizingPath
        }
        return links
    }
}
