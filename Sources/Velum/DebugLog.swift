import Foundation

/// Velum's optional debug log (••• → Debug Logging). Off by default. When on, Velum appends what changed and
/// what went wrong to `~/Library/Logs/Velum/Velum.log`, so a glitch can be looked at afterwards:
/// - every account's status changes, services and accounts coming and going, the lid line;
/// - alerts it showed, actions clicked in Velum (Start, Restart, Quit);
/// - gaps where macOS dropped change events, background checks that failed (`brctl`, Google Drive's
///   database), and the optional Google sign-in's events.
/// It never writes file contents or sign-in tokens. Status lines can carry a failing file's name, as the
/// panel does; it stays on this Mac. The file rotates at 2 MB, keeping one previous file (`Velum.1.log`).
/// Safe to call from any thread; a no-op while off.
final class DebugLog: @unchecked Sendable {
    static let shared = DebugLog()
    static let defaultsKey = "debugLogging"

    let file: URL
    private let previous: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Velum.debuglog", qos: .utility)
    private let lock = NSLock()
    private var enabled: Bool
    private let maxSize: UInt64
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Velum"),
         defaults: UserDefaults = .standard, maxSize: UInt64 = 2_000_000) {
        file = directory.appending(path: "Velum.log")
        previous = directory.appending(path: "Velum.1.log")
        self.defaults = defaults
        self.maxSize = maxSize
        enabled = defaults.bool(forKey: Self.defaultsKey)
    }

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            guard newValue != isEnabled else { return }
            if !newValue { write("log", "Debug logging turned off") }
            lock.withLock { enabled = newValue }
            defaults.set(newValue, forKey: Self.defaultsKey)
            if newValue { write("log", "Debug logging turned on · \(Self.versions)") }
        }
    }

    static var versions: String {
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev build"
        return "Velum \(app) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// Appends one line, "2026-11-12 23:45:01.123 [category] message", when logging is on.
    func log(_ category: String, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        write(category, message())
    }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }

    private func write(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)\n"
        queue.async { [file, previous, maxSize] in
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? UInt64, size > maxSize {
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: file, to: previous)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    // MARK: What changed between two refreshes

    /// Human-readable lines for what changed from `old` to `new` (everything, when `old` is nil). Only
    /// meaningful changes: a status, its source, counts, coverage, notes; not "last activity 3 min ago".
    static func changes(from old: Snapshot?, to new: Snapshot) -> [String] {
        var lines: [String] = []
        let oldProviders = Dictionary(uniqueKeysWithValues: (old?.providers ?? []).map { ($0.id, $0) })
        let newProviders = Dictionary(uniqueKeysWithValues: new.providers.map { ($0.id, $0) })
        for provider in new.providers {
            let name = provider.id.name
            guard let before = oldProviders[provider.id] else {
                lines.append("\(name): found\(running(provider))")
                continue
            }
            if before.clientRunning != provider.clientRunning {
                lines.append(provider.clientRunning == true ? "\(name): app started" : "\(name): app stopped")
            }
            if before.trouble != provider.trouble {
                lines.append("\(name): \(provider.trouble ?? "no service-wide trouble")")
            }
        }
        for provider in old?.providers ?? [] where newProviders[provider.id] == nil {
            lines.append("\(provider.id.name): gone (no live accounts)")
        }

        let oldAccounts = Dictionary(uniqueKeysWithValues: (old?.accounts ?? []).map { ($0.id, $0) })
        let newIDs = Set(new.accounts.map(\.id))
        for account in new.accounts {
            guard let before = oldAccounts[account.id] else {
                lines.append("\(account.name) [\(account.provider.name)]: appeared · \(describe(account))")
                continue
            }
            if before.state != account.state || before.headline != account.headline || before.source != account.source {
                lines.append("\(account.name): \(before.state) → \(account.state) · \(describe(account))")
            }
            if before.uploadsFailed != account.uploadsFailed, let failure = account.firstFailure {
                lines.append("\(account.name): \(account.uploadsFailed) failing · first: \(failure)")
            }
            if before.uploadsCovered != account.uploadsCovered {
                lines.append(account.uploadsCovered
                             ? "\(account.name): watching every change again"
                             : "\(account.name): Velum may have missed changes (gap, or not watching yet)")
            }
            if before.notes != account.notes, !account.notes.isEmpty {
                lines.append("\(account.name): \(account.notes)")
            }
        }
        for account in old?.accounts ?? [] where !newIDs.contains(account.id) {
            lines.append("\(account.name) [\(account.provider.name)]: gone")
        }
        if old == nil || old?.lidVerdict != new.lidVerdict {
            lines.append("Lid: \(new.lidVerdict)")
        }
        return lines
    }

    private static func running(_ provider: ProviderStatus) -> String {
        switch provider.clientRunning {
        case true?: " · app running"
        case false?: " · app not running"
        case nil: ""
        }
    }

    private static func describe(_ account: AccountStatus) -> String {
        var parts = [account.headline]
        if !account.source.isEmpty { parts.append(account.source) }
        if account.uploadsPending > 0 { parts.append("\(account.uploadsPending) pending") }
        if account.workPending { parts.append("service still working") }
        return parts.joined(separator: " · ")
    }
}

/// Shorthand for `DebugLog.shared.log`.
func debugLog(_ category: String, _ message: @autoclosure () -> String) {
    DebugLog.shared.log(category, message())
}
