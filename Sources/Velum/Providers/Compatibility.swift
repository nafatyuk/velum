import AppKit
import SQLite3

// Card A7: Velum reads internals no sync client promised to keep (OneDrive's report, databases and
// settings; Google Drive's database and links; iCloud's `brctl` answers). Each one is checked every time
// Velum reads it, against what was tested. One that no longer reads as tested is dropped as evidence, never
// guessed at:
// - the statuses that leaned on it become unknown, with a reason on the row;
// - the lid line stops saying "safe" when the lid relied on it (Google Drive's queue, a folder no row watches);
// - the debug log and `Velum --dump` say what changed;
// - a changed shape (a missing line, column, table or tool) alerts once per client version.
// A new client version whose every check passes changes nothing; it is only recorded. Decisions and wording
// by the Codex and Fable consult (November 13, 2026).

/// One internal Velum reads, as last checked.
struct InternalCheck: Equatable {
    enum Result: String {
        /// Reads as tested.
        case fine = "ok"
        /// Not there (yet): nothing to read, and not a change by itself (a new account's first report).
        case missing
        /// Read, but with a value Velum has never seen (a status code): more likely old and rare than new, so
        /// that value counts as unknown and is recorded, without an alert.
        case unrecognized
        /// Can't be read right now, or not covered (a live folder no row watches). Not a change: no alert.
        case unavailable
        /// There, but not in the shape that was tested: Velum stops using it, and says so once per version.
        case changed
    }

    /// What the dump and the debug log call it: "status report (SyncDiagnostics.log)".
    let name: String
    /// Whose: the account's key and name; nil for the whole service.
    var accountKey: String?
    var accountName: String?
    var result: Result
    var detail = ""
    /// While this one isn't fine, the lid line doesn't say "safe": the lid relied on it.
    var guardsLid = false
    /// No alert even when changed: what it feeds is optional and its absence can be legitimate (storage).
    var quiet = false
    /// What the alert calls it ("status report"), the row's reason, and the lid's reason.
    var phrase = ""
    var note: String?
    var lidReason: String?

    /// Changes what Velum shows: the row's reason, and the lid when it guards the lid.
    var counts: Bool { result != .fine && result != .missing }
    var alerts: Bool { result == .changed && !quiet }
    var key: String { name + "|" + (accountKey ?? "") }
}

/// A service's checks, with the client version they ran against.
struct CompatibilityReport: Equatable {
    let provider: ProviderID
    /// As the client states it ("26.212.1029"); for iCloud, macOS's version. nil when it can't be read.
    var version: String?
    var checks: [InternalCheck] = []

    var counted: [InternalCheck] { checks.filter(\.counts) }
    var alerting: [InternalCheck] { checks.filter(\.alerts) }
    var isTested: Bool { version.map(provider.isTested) ?? false }
    /// "OneDrive 26.212", "Google Drive 133", "macOS 27.3"; the bare name when the version can't be read.
    var client: String { [provider.versionOwner, version.map(provider.shortVersion)].compactMap { $0 }.joined(separator: " ") }
    /// The alert's identity: one alert per service and release, ever.
    var alertKey: String { provider.rawValue + " " + (version.map(provider.shortVersion) ?? "?") }
    /// Why the lid can't vouch, from the first check that guards it and isn't fine; nil when it can.
    var lidReason: String? {
        counted.first(where: \.guardsLid).map { $0.lidReason ?? "Velum can’t read part of \(client)" }
    }

    /// The reasons for one account's row: its own checks and the whole service's, once each.
    func notes(for accountKey: String) -> [String] {
        var seen = Set<String>()
        return counted.filter { $0.accountKey == nil || $0.accountKey == accountKey }
            .compactMap(\.note).filter { seen.insert($0).inserted }
    }

    /// Puts the reasons on the rows (as `compatibilityNote`, which card A4's reason line shows), hands the
    /// report on, and debug-logs what changed since the last report.
    func record(into evidence: inout ProviderEvidence, logged: inout CompatibilityReport?) {
        for i in evidence.accounts.indices {
            let notes = notes(for: evidence.accounts[i].config.key)
            guard !notes.isEmpty else { continue }
            evidence.accounts[i].compatibilityNote = notes.joined(separator: " · ")
        }
        evidence.compatibility = self
        for line in changes(from: logged) { debugLog("compat", line) }
        logged = self
    }

    /// "OneDrive 26.212 (26.212.1029) · tested · every check passes".
    var headline: String {
        var parts = [client + (version.map { $0 != provider.shortVersion($0) ? " (\($0))" : "" } ?? " (version unknown)")]
        parts.append(isTested ? "tested" : "not tested (tested: \(provider.testedVersions.joined(separator: ", ")))")
        if provider == .iCloud { parts[0] += ", for iCloud" }
        if checks.isEmpty {
            parts.append("nothing checked yet")      // iCloud's first `brctl` answers take about 15 s
        } else if counted.isEmpty {
            parts.append(isTested ? "every check passes" : "every check that could run passes")
        } else {
            let alerting = alerting.count
            parts.append("\(counted.count) not as tested" + (alerting > 0 ? ", \(alerting) changed" : ""))
        }
        return parts.joined(separator: " · ")
    }

    /// For `--dump`: the headline, then one line per check.
    var dumpLines: [String] {
        ["  " + headline] + checks.map { "    " + Self.line($0) }
    }

    /// "ok  status report · Personal: code 16777216", "status report · Personal: unknown code 4096 (recorded, no alert)".
    static func line(_ check: InternalCheck) -> String {
        let whose = check.accountName.map { " · \($0)" } ?? ""
        let detail = check.detail.isEmpty ? "" : " (\(check.detail))"
        switch check.result {
        case .fine: return "ok  \(check.name)\(whose)\(check.detail.isEmpty ? "" : ": \(check.detail)")"
        case .missing: return "--  \(check.name)\(whose): not there yet\(detail)"
        case .unrecognized: return "??  \(check.name)\(whose): \(check.detail) (recorded, no alert)"
        case .unavailable: return "!!  \(check.name)\(whose): \(check.detail)\(check.guardsLid ? " (the lid can’t vouch)" : "")"
        case .changed: return "XX  \(check.name)\(whose): changed\(detail)\(check.quiet ? ", no alert" : "")"
        }
    }

    /// Debug-log lines for what changed since `old`: the version (first seen, or updated), and every check whose
    /// result moved (or whose detail moved while it isn't fine). Nothing when all is as before.
    func changes(from old: CompatibilityReport?) -> [String] {
        var lines: [String] = []
        if old == nil || old?.version != version {
            let head = old.map { "\(provider.versionOwner) updated from \($0.version ?? "an unknown version"): " } ?? ""
            lines.append(head + headline)
        }
        let before = Dictionary((old?.checks ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for check in checks {
            let previous = before[check.key]
            if old == nil, check.result == .fine { continue }      // the first report's headline covers what's fine
            guard previous?.result != check.result || (check.result != .fine && previous?.detail != check.detail) else { continue }
            lines.append("\(provider.name): " + Self.line(check))
        }
        let now = Set(checks.map(\.key))
        for check in old?.checks ?? [] where !now.contains(check.key) && check.counts {
            lines.append("\(provider.name): \(check.name)\(check.accountName.map { " · \($0)" } ?? ""): no longer checked")
        }
        return lines
    }
}

extension ProviderID {
    /// The versions Velum was tested with. Keep the README's "tested with" line in step. Major.minor for OneDrive
    /// and macOS, major for Google Drive, as each numbers its releases; a build matches its release
    /// ("26.212.1029" is 26.212).
    var testedVersions: [String] {
        switch self {
        case .oneDrive: ["26.204", "26.212"]
        case .googleDrive: ["133"]
        case .iCloud: ["27.3"]          // macOS: iCloud's `brctl` comes with it
        case .cloudStorage: ["27.3"]    // macOS, whose File Provider the generic tier reads; no client tested (C3)
        }
    }

    /// Whose version decides how the internals read: the app's, or macOS's for iCloud.
    var versionOwner: String { self == .iCloud ? "macOS" : name }

    func isTested(_ version: String) -> Bool {
        testedVersions.contains { version == $0 || version.hasPrefix($0 + ".") }
    }

    /// The release as people name it: "26.212" for build 26.212.1029, "133" for 133.0, "27.3".
    func shortVersion(_ version: String) -> String {
        let parts = testedVersions.first?.split(separator: ".").count ?? 2
        return version.split(separator: ".").prefix(parts).joined(separator: ".")
    }
}

/// Where each client's version comes from.
enum ClientVersion {
    /// The installed app's version. Read from its Info.plist every time: `Bundle` caches it, and the app can
    /// update underneath a running Velum.
    static func installed(bundleID: String) -> String? {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }?.bundleURL
        guard let app = running ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return version(ofAppAt: app)
    }

    static func version(ofAppAt app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["CFBundleShortVersionString"] as? String else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// "27.3", or "27.3.1" with a patch.
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }
}

/// A table's columns in another app's SQLite database, read-only. Tells a changed shape (no table, not a
/// database) from a passing hiccup (locked, busy), which never counts as a change.
enum SQLiteSchema {
    enum Read: Equatable {
        case columns(Set<String>)
        case noTable
        case noFile
        case notADatabase
        case busy
    }

    static func columns(of table: String, in path: String) -> Read {
        guard FileManager.default.fileExists(atPath: path) else { return .noFile }
        var db: OpaquePointer?
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let code = sqlite3_errcode(db)
            sqlite3_close(db)
            return code == SQLITE_NOTADB ? .notADatabase : .busy
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM pragma_table_info(?)", -1, &stmt, nil) == SQLITE_OK else {
            return sqlite3_errcode(db) == SQLITE_NOTADB ? .notADatabase : .busy
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        var names = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return step == SQLITE_NOTADB ? .notADatabase : .busy }
            if let name = sqlite3_column_text(stmt, 0) { names.insert(String(cString: name)) }
        }
        return names.isEmpty ? .noTable : .columns(names)
    }

    /// The result of checking `table` for its `required` columns; nil for a passing hiccup (keep the last answer).
    static func check(_ read: Read, table: String, required: [String]) -> (InternalCheck.Result, String)? {
        switch read {
        case .busy: return nil
        case .noFile: return (.changed, "the database is gone")
        case .notADatabase: return (.changed, "the file isn’t a database Velum can read")
        case .noTable: return (.changed, "no \(table) table")
        case .columns(let names):
            let missing = required.filter { !names.contains($0) }
            return missing.isEmpty ? (.fine, "") : (.changed, "no \(missing.joined(separator: ", ")) column\(missing.count == 1 ? "" : "s")")
        }
    }
}

/// Live File Provider roots of a service that no shown account watches. One that stays unwatched for a minute
/// stops the lid from vouching (the lid's claim covers every folder of a service Velum shows); it never alerts.
final class UnwatchedRoots {
    static let grace: TimeInterval = 60
    private var since: [String: Date] = [:]

    /// The check, or nil when every live root is watched.
    func check(live roots: [URL], watched: [AccountConfig], provider: ProviderID, now: Date) -> InternalCheck? {
        let covered = watched.flatMap(\.watchRoots).map(\.standardizedFileURL.path)
        let stray = roots.filter { root in
            let path = root.standardizedFileURL.path
            return !covered.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        let names = Set(stray.map(\.lastPathComponent))
        since = since.filter { names.contains($0.key) }
        for name in names where since[name] == nil { since[name] = now }
        guard !stray.isEmpty else { return nil }
        let lasting = names.filter { now.timeIntervalSince(since[$0] ?? now) >= Self.grace }.sorted()
        return InternalCheck(
            name: "live folders", result: lasting.isEmpty ? .fine : .unavailable,
            detail: lasting.isEmpty ? "just appeared, not watched yet: \(names.sorted().joined(separator: ", "))"
                                    : "live folder not watched: \(lasting.joined(separator: ", "))",
            guardsLid: true, lidReason: CompatibilityText.lidUnwatched(provider))
    }
}

/// One alert per client release that changed the shape of something Velum reads, remembered across launches.
/// A release must keep failing for `settle` seconds first: clients relaunch and rewrite their files right
/// after updating. No "resolved" follow-up: the row's reason goes away by itself.
final class CompatibilityAlerts {
    static let defaultsKey = "compatibilityAlerted"
    let settle: TimeInterval = 60
    private let defaults: UserDefaults
    private var failingSince: [String: Date] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The alerts due now, each marked as sent: also when alerts are off, so switching them on later doesn't
    /// replay old news.
    func due(_ providers: [ProviderStatus], now: Date) -> [(key: String, title: String, body: String)] {
        var alerted = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        var failing = Set<String>()
        var due: [(key: String, title: String, body: String)] = []
        for report in providers.compactMap(\.compatibility) where !report.alerting.isEmpty {
            let key = report.alertKey
            failing.insert(key)
            guard !alerted.contains(key) else { continue }
            let since = failingSince[key] ?? now
            failingSince[key] = since
            guard now.timeIntervalSince(since) >= settle else { continue }
            alerted.append(key)
            due.append(("compat:\(key)", CompatibilityText.alertTitle(report), CompatibilityText.alertBody(report)))
        }
        failingSince = failingSince.filter { failing.contains($0.key) }
        if !due.isEmpty { defaults.set(Array(alerted.suffix(50)), forKey: Self.defaultsKey) }
        return due
    }
}

/// Every sentence card A7 shows, in one place. Fable's rules: "Can’t read", true whether the client changed or
/// a file is damaged; service first; what still holds after the dot ("uploads are still tracked").
enum CompatibilityText {
    // The alert.
    static func alertTitle(_ report: CompatibilityReport) -> String {
        report.provider == .iCloud ? "Velum can’t read part of iCloud on \(report.client)" : "Velum can’t read part of \(report.client)"
    }

    static func alertBody(_ report: CompatibilityReport) -> String {
        var phrases: [String] = []
        for phrase in report.alerting.map(\.phrase) where !phrase.isEmpty && !phrases.contains(phrase) { phrases.append(phrase) }
        let what = phrases.isEmpty ? "part of it" : "\(report.provider.name)’s \(list(phrases))"
        return "Velum isn’t using \(what) for now. Open Cloud Sync to see what’s affected."
    }

    // The row's reason. `client` is "OneDrive 27.0", "Google Drive 134", "macOS 28.0".
    static func oneDriveSettings(_ client: String) -> String { "Found from its folder · Velum can’t read \(client)’s settings" }
    static func oneDriveReport(_ client: String) -> String { "Can’t read \(client)’s status report · uploads are still tracked" }
    static let oneDriveCode = "OneDrive reported a status Velum doesn’t know · uploads are still tracked"
    static func oneDriveActivity(_ client: String) -> String { "Can’t read \(client)’s activity list · not shown in Recent" }
    static let oneDriveProcesses = "Can’t tell whether OneDrive is running for this account"
    static func googleNaming(_ client: String) -> String { "Found from \(client)’s own files · uploads are still tracked" }
    static func googleData(_ client: String) -> String { "Can’t find this account’s \(client) data · only uploads are tracked" }
    static func googleQueue(_ client: String) -> String { "Can’t read \(client)’s queue · only uploads are tracked" }
    static let googleQueueNow = "Can’t read Google Drive’s queue right now · checking again"
    static func iCloudReport(_ client: String) -> String { "Can’t read iCloud’s status report on \(client) · uploads are still tracked" }

    // The lid's reason: the clause only; the panel adds the period under "Can’t vouch for every change".
    static func lidUnwatched(_ provider: ProviderID) -> String { "Velum isn’t watching every \(provider.name) folder" }
    static let lidQueue = "Velum can’t read Google Drive’s queue"

    /// "a", "a and b", "a, b and c".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}
