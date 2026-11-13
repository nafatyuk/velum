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
    /// When Velum first saw each account with no usable report, for "One is due by …" (A4).
    private var noReportSince: [String: Date] = [:]
    private let defaults = UserDefaults.standard
    /// Checks every internal read here against the tested versions (card A7).
    private let compat = OneDriveCompatibility()

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        if force || now.timeIntervalSince(lastDiscovery) > 60 {
            configs = compat.discovered(OneDriveFiles.discoverAccounts(), now: now)
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
        // Present only with at least one live account: OneDrive installed but signed out of everything, or
        // uninstalled with its settings left behind, shows nothing rather than an error.
        evidence.present = !configs.isEmpty
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
            account.report = Self.report(from: diag, now: now)
            if account.report == nil {
                let since = noReportSince[config.key] ?? now
                noReportSince[config.key] = since
                account.unknownReason = Self.noReportReason(diag: diag, since: since, now: now)
            } else {
                noReportSince[config.key] = nil
            }
            account.lastActivity = history.first?.date
            evidence.accounts.append(account)
        }
        compat.apply(&evidence, mappingUnknown: mappingUnknown, now: now)
        return evidence
    }

    /// How often OneDrive writes its report while it runs and the Mac is awake.
    static let reportEvery: TimeInterval = 60 * 60

    /// OneDrive's hourly report as an account-wide status. The codes are community-documented; Microsoft
    /// doesn't publish them. A code Velum doesn't know reads as unknown, never as healthy.
    static func report(from diag: Diagnostics?, now: Date = Date()) -> ProviderReport? {
        guard let diag, let code = diag.progressState else { return nil }
        var report = ProviderReport(label: "OneDrive report", written: diag.written, state: .unknown, headline: "Can’t tell",
                                    every: reportEvery)
        switch code {
        case 65536: report.state = .paused; report.headline = "Paused"
        case 8194: report.state = .offline; report.headline = "Not syncing"
        case 1854: report.state = .error; report.headline = "Sync issue"
        case 0, 16777216: report.state = .ok; report.headline = "Up to date"
        default: break
        }
        report.reason = reason(for: report, code: code, now: now)
        return report
    }

    // MARK: Reasons (A4): why a row can't tell, and what would end it

    /// The reason for a report that leaves the status unknown or old; nil for a fresh, known one.
    static func reason(for report: ProviderReport, code: Int, now: Date) -> String? {
        let due = RelTime.clock(report.written.addingTimeInterval(reportEvery))
        if report.isOld(now: now) {
            let age = Reasons.duration(now.timeIntervalSince(report.written))
            let hourly = "It reports about hourly while it runs and this Mac is awake."
            if report.state == .ok {
                return "OneDrive last reported “\(report.headline)” at \(RelTime.clock(report.written)), \(age) ago. \(hourly)"
            }
            if report.state == .unknown {
                return "OneDrive’s last report, at \(RelTime.clock(report.written)), is \(age) old. \(hourly)"
            }
            return "This report is \(age) old. OneDrive may have changed since."
        }
        guard report.state == .unknown else { return nil }
        let next = now > report.written.addingTimeInterval(reportEvery) ? "Its next report is overdue." : "Its next report is due by \(due)."
        return "OneDrive reported a status Velum doesn’t recognize (code \(code)). \(next)"
    }

    /// No usable report: none written yet, none since Velum started looking, or one with no status line.
    static func noReportReason(diag: Diagnostics?, since: Date, now: Date) -> String {
        if let diag {
            return "OneDrive’s report at \(RelTime.clock(diag.written)) had no status Velum can read. Velum keeps looking."
        }
        let due = since.addingTimeInterval(reportEvery)
        // A first sighting can't date the next report, so no time is promised (Codex, Fable).
        if now <= due {
            return "No OneDrive report yet. OneDrive usually writes one about every hour while it runs and this Mac is awake."
        }
        return "No OneDrive report since \(RelTime.clock(since)), though it writes one about every hour while this Mac is awake."
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
        // A failed read (the file is there, nothing came back) is retried next pass, not kept for the hour (A7).
        if !force, let cached = diagCache[key], cached.stamp == stamp, cached.value != nil || stamp == nil { return cached.value }
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
