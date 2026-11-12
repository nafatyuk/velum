import AppKit

/// OneDrive as a provider: its accounts come from its settings files, one process per account, the text
/// on its own menu bar icons (Accessibility, opt-in), its hourly diagnostics report and its activity
/// database. Read-only: nothing here writes to OneDrive. Used only from the collector's serial queue.
final class OneDriveProvider: SyncProvider, @unchecked Sendable {
    let id = ProviderID.oneDrive

    private var configs: [AccountConfig] = []
    private var lastDiscovery = Date.distantPast
    private var pidKeys: [pid_t: Set<String>] = [:]
    private var diagCache: [String: (stamp: Date?, value: Diagnostics?)] = [:]
    private var activityCache: [String: (stamp: Date?, value: [Activity])] = [:]
    private let defaults = UserDefaults.standard
    private lazy var installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: oneDriveBundleID) != nil

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        if force || configs.isEmpty || now.timeIntervalSince(lastDiscovery) > 60 {
            configs = OneDriveFiles.discoverAccounts()
            lastDiscovery = now
        }

        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: oneDriveBundleID).filter { !$0.isTerminated }
        var mapping: [pid_t: Set<String>] = [:]
        for app in apps {
            let pid = app.processIdentifier
            if let known = pidKeys[pid], !known.isEmpty {
                mapping[pid] = known
            } else {
                mapping[pid] = OneDriveFiles.accountKeys(openedBy: pid)
            }
        }
        pidKeys = mapping
        let mappingUnknown = !apps.isEmpty && mapping.values.allSatisfy(\.isEmpty)

        let live = LiveStatus.read()
        var evidence = ProviderEvidence()
        evidence.present = installed || !configs.isEmpty || !apps.isEmpty
        evidence.clientRunning = !apps.isEmpty
        evidence.axTrusted = LiveStatus.isTrusted
        evidence.liveItemsFound = !live.isEmpty

        for config in configs {
            let diag = diagnostics(config.key, force: force)
            let history = activity(config.key, force: force)
            evidence.activity += history

            var pid = mapping.first(where: { $0.value.contains(config.key) })?.key
            if pid == nil, let p = diag?.pid, mapping[p] != nil, mappingUnknown { pid = p }

            let liveItem = live.first(where: { pid != nil && $0.pid == pid })
                ?? live.first(where: { Self.sameAccount($0.name, config) })
            if let liveItem, !liveItem.name.isEmpty {
                defaults.set(liveItem.name, forKey: "name.\(config.key)")
            }
            let name = liveItem?.name ?? defaults.string(forKey: "name.\(config.key)") ?? config.fallbackName

            var account = AccountEvidence(config: config, name: name)
            account.running = pid != nil || mappingUnknown
            account.pid = pid
            account.exactStatus = liveItem?.status
            account.report = Self.report(from: diag)
            account.lastActivity = history.first?.date
            evidence.accounts.append(account)
        }
        return evidence
    }

    /// OneDrive's hourly report as an account-wide status. The codes are community-documented; Microsoft
    /// doesn't publish them. A code Velum doesn't know reads as unknown, never as healthy.
    static func report(from diag: Diagnostics?) -> ProviderReport? {
        guard let diag, let code = diag.progressState else { return nil }
        var report = ProviderReport(label: "OneDrive report", written: diag.written, state: .unknown, headline: "Status unknown")
        switch code {
        case 65536: report.state = .paused; report.headline = "Paused"
        case 8194: report.state = .offline; report.headline = "Not syncing"
        case 1854: report.state = .error; report.headline = "Sync issue"
        case 0, 16777216: report.state = .ok; report.headline = "Up to date"
        default: break
        }
        return report
    }

    static func sameAccount(_ liveName: String, _ config: AccountConfig) -> Bool {
        let n = normalized(liveName)
        guard !n.isEmpty else { return false }
        let folderName = config.folder.lastPathComponent.replacingOccurrences(of: "OneDrive-", with: "")
        return n == normalized(folderName) || n == normalized(config.fallbackName)
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func diagnostics(_ key: String, force: Bool) -> Diagnostics? {
        let path = OneDriveFiles.diagnosticsPath(key)
        let stamp = OneDriveFiles.modificationDate(path)
        if !force, let cached = diagCache[key], cached.stamp == stamp { return cached.value }
        let value = OneDriveFiles.diagnostics(at: path)
        diagCache[key] = (stamp, value)
        return value
    }

    private func activity(_ key: String, force: Bool) -> [Activity] {
        let stamp = OneDriveFiles.activityStamp(key)
        if !force, let cached = activityCache[key], cached.stamp == stamp { return cached.value }
        let value = OneDriveFiles.activity(key)
        activityCache[key] = (stamp, value)
        return value
    }
}
