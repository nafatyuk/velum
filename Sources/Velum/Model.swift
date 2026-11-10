import AppKit
import Combine

/// Ordered by how much attention it needs; the menu bar icon shows the worst one.
enum SyncState: Int, Comparable {
    /// `unknown`: Velum has no evidence either way. Shown as a plain cloud, never as "Up to date".
    case ok, unknown, syncing, offline, paused, warning, notRunning, error

    static func < (a: SyncState, b: SyncState) -> Bool { a.rawValue < b.rawValue }

    /// Maps OneDrive's own status wording (see its StatusIcon* strings) to a state.
    static func classify(_ text: String) -> SyncState {
        let s = text.lowercased().replacingOccurrences(of: "’", with: "'")
        if s.contains("paused") { return .paused }
        if s.contains("offline") { return .offline }
        let problems = ["sign in", "sync issue", "can't", "couldn't", "error", "out of space", "is full",
                        "over your storage", "isn't enough space"]
        if problems.contains(where: s.contains) { return .error }
        if s.contains("% full") { return .warning }
        let busy = ["syncing", "uploading", "downloading", "transferring", "processing", "looking for changes",
                    "moving", "signing in"]
        if busy.contains(where: s.contains) { return .syncing }
        let healthy = ["synced", "up to date", "online"]
        if healthy.contains(where: s.contains) { return .ok }
        return .unknown   // wording we don't recognise (another language, a new OneDrive message)
    }
}

struct AccountStatus: Identifiable, Equatable {
    let config: AccountConfig
    let name: String
    let state: SyncState
    let headline: String
    let detail: String
    /// Where the headline came from: "From OneDrive", "Live from macOS", "OneDrive report, 1:45 PM".
    let source: String
    let pid: pid_t?
    let isLive: Bool
    let lastActivity: Date?
    /// Local changes not in the cloud yet (waiting or uploading), and ones that failed.
    var uploadsPending = 0
    var uploadsFailed = 0
    var firstFailure: String?
    var oldestWaiting: Date?
    /// Velum is watching this account's folder with no known gaps, so the counts above are complete.
    var uploadsCovered = false

    var id: String { config.key }
}

/// The answer to "is it safe to close the lid?": is every local change in the cloud?
enum LidVerdict: Equatable {
    case safe
    case pending(Int)
    case failing(Int)
    case notRunning
    case unknown(String)
}

struct Snapshot: Equatable {
    var accounts: [AccountStatus] = []
    var activity: [Activity] = []
    var oneDriveRunning = false
    var axTrusted = false
    var liveItemsFound = false
}

/// Gathers everything off the main thread. Only ever used from one serial queue.
final class Collector: @unchecked Sendable {
    private var configs: [AccountConfig] = []
    private var lastDiscovery = Date.distantPast
    private var pidKeys: [pid_t: Set<String>] = [:]
    private var diagCache: [String: (stamp: Date?, value: Diagnostics?)] = [:]
    private var activityCache: [String: (stamp: Date?, value: [Activity])] = [:]
    private let defaults = UserDefaults.standard

    func collect(force: Bool, transfers: [String: TransferInfo] = [:],
                 uploads: (watching: Set<String>, accounts: [String: UploadSummary]) = ([], [:])) -> Snapshot {
        let now = Date()
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
        var snapshot = Snapshot()
        snapshot.oneDriveRunning = !apps.isEmpty
        snapshot.axTrusted = LiveStatus.isTrusted
        snapshot.liveItemsFound = !live.isEmpty

        var everything: [Activity] = []
        for config in configs {
            let diag = diagnostics(config.key, force: force)
            let history = activity(config.key, force: force)
            everything += history

            var pid = mapping.first(where: { $0.value.contains(config.key) })?.key
            if pid == nil, let p = diag?.pid, mapping[p] != nil, mappingUnknown { pid = p }
            let running = pid != nil || mappingUnknown

            let liveItem = live.first(where: { pid != nil && $0.pid == pid })
                ?? live.first(where: { Self.sameAccount($0.name, config) })
            if let liveItem, !liveItem.name.isEmpty {
                defaults.set(liveItem.name, forKey: "name.\(config.key)")
            }
            let name = liveItem?.name ?? defaults.string(forKey: "name.\(config.key)") ?? config.fallbackName

            snapshot.accounts.append(Self.status(
                config: config, name: name, running: running, pid: pid, live: liveItem,
                transfer: transfers[config.key], uploads: uploads.accounts[config.key],
                watchingUploads: uploads.watching.contains(config.key),
                diag: diag, lastActivity: history.first?.date, now: now
            ))
        }
        everything.sort { $0.date > $1.date }
        snapshot.activity = Array(everything.prefix(25))
        return snapshot
    }

    /// Status sources, most authoritative first: OneDrive's own icon text (only readable while its icons
    /// exist), live File Provider state (changed files' upload flags and transfer progress), then
    /// OneDrive's hourly report. With no evidence the state is `.unknown`, never "Up to date".
    static func status(config: AccountConfig, name: String, running: Bool, pid: pid_t?, live: LiveItem?,
                       transfer: TransferInfo?, uploads: UploadSummary?, watchingUploads: Bool,
                       diag: Diagnostics?, lastActivity: Date?, now: Date) -> AccountStatus {
        var state = SyncState.unknown
        var headline = "No status yet"
        var source = ""
        var extra: [String] = []

        let failed = uploads?.failed ?? []
        let uploading = max(uploads?.uploading ?? 0, transfer?.uploadingFiles ?? 0)
        let downloading = transfer?.downloadingFiles ?? 0
        let moving = uploading + downloading
        // Direction-less per-file progress: OneDrive publishes two objects per uploaded file, so it only
        // says "something is moving", never how many.
        let unlabelled = (transfer?.otherFiles ?? 0) > 0
        let waiting = uploads?.waiting ?? 0
        let reportTime = diag.map { "OneDrive report, \(RelTime.clock($0.written))" } ?? ""
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

        if !running {
            state = .notRunning
            headline = "Not running, so nothing is syncing"
        } else if let live, !live.status.isEmpty {
            state = SyncState.classify(live.status)
            headline = live.status
            source = "From OneDrive"
        } else if !failed.isEmpty {
            state = .error
            headline = failed.count == 1 ? "1 file can't upload" : "\(failed.count) files can't upload"
            extra.append(failed[0])
            source = "Live from macOS"
        } else if moving > 0 {
            state = .syncing
            if downloading == 0 {
                headline = "Uploading \(files(uploading))"
            } else if uploading == 0 {
                headline = "Downloading \(files(downloading))"
            } else {
                headline = "Syncing \(files(moving))"
            }
            if let bytes = transfer?.bytesText { extra.append(bytes) }
            source = "Live from macOS"
        } else if waiting > 0 {
            // Community-documented code: 65536 = paused. Microsoft doesn't publish these.
            let paused = diag?.progressState == 65536
            state = paused ? .paused : .syncing
            headline = paused ? "Paused, \(files(waiting)) waiting" : "Waiting to upload \(files(waiting))"
            if let oldest = uploads?.oldestWaiting, now.timeIntervalSince(oldest) > 10 * 60 {
                extra.append("waiting since \(RelTime.clock(oldest))")
            }
            source = "Live from macOS"
        } else if unlabelled {
            state = .syncing
            headline = "Syncing changes"
            source = "Live from macOS"
        } else if let code = diag?.progressState {
            // Community-documented values from OneDrive's hourly diagnostics report.
            switch code {
            case 65536: state = .paused; headline = "Paused"; source = reportTime
            case 8194: state = .offline; headline = "Not syncing"; source = reportTime
            case 1854: state = .error; headline = "Sync issue"; source = reportTime
            case 0, 16777216:
                // A healthy report plus, when Velum is watching with no gaps, nothing pending right now.
                state = .ok
                headline = "Up to date"
                let liveCoverage = watchingUploads && uploads?.coverageGap != true
                source = liveCoverage ? "Nothing pending · \(reportTime)" : reportTime
            default:
                state = .unknown
                headline = "Status unknown"
                source = reportTime
            }
        }

        var details = extra
        if !source.isEmpty { details.append(source) }
        if let last = lastActivity { details.append("last activity \(RelTime.string(last, now: now))") }

        var status = AccountStatus(config: config, name: name, state: state, headline: headline,
                                   detail: details.joined(separator: " · "), source: source, pid: pid,
                                   isLive: live != nil, lastActivity: lastActivity)
        status.uploadsPending = (uploads?.waiting ?? 0) + uploading
        status.uploadsFailed = failed.count
        status.firstFailure = failed.first
        status.oldestWaiting = uploads?.oldestWaiting
        status.uploadsCovered = running && watchingUploads && uploads?.coverageGap != true
        return status
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

@MainActor
final class Store: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var loginItemEnabled = false
    @Published var notificationsEnabled = UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    /// Called with every finished refresh (changed or not), so time-based checks keep running.
    var onRefresh: ((Snapshot) -> Void)?
    /// Set after "Turn On…" so the tip can offer a restart, which macOS sometimes needs before the
    /// Accessibility switch takes effect.
    @Published var exactStatusRequested = false
    @Published var exactStatusTipDismissed = UserDefaults.standard.bool(forKey: "exactStatusTipDismissed") {
        didSet { UserDefaults.standard.set(exactStatusTipDismissed, forKey: "exactStatusTipDismissed") }
    }

    private let collector = Collector()
    private let transfers = TransferMonitor()
    private let uploadTracker = UploadTracker()
    private let queue = DispatchQueue(label: "Velum.collect", qos: .utility)
    private var timer: Timer?
    private var inFlight = false
    private var pending = false
    private var pendingForce = false
    private var observers: [NSObjectProtocol] = []

    var accounts: [AccountStatus] { snapshot.accounts }
    var activity: [Activity] { snapshot.activity }

    var overallState: SyncState {
        if !snapshot.oneDriveRunning { return .notRunning }
        return snapshot.accounts.map(\.state).max() ?? .ok
    }

    var summary: String {
        if snapshot.accounts.isEmpty {
            return snapshot.oneDriveRunning ? "No synced accounts found" : "OneDrive isn’t running"
        }
        let attention = snapshot.accounts.filter { $0.state != .ok }
        if attention.isEmpty {
            switch snapshot.accounts.count {
            case 1: return "Up to date"
            case 2: return "Both accounts are up to date"
            default: return "All accounts are up to date"
            }
        }
        return attention.map { "\($0.name): \($0.headline)" }.joined(separator: " · ")
    }

    /// Read by VoiceOver on the menu bar icon: one sentence per account.
    var accessibilitySummary: String {
        if snapshot.accounts.isEmpty { return "OneDrive: \(summary)" }
        return "OneDrive. " + snapshot.accounts.map { "\($0.name): \($0.headline)." }.joined(separator: " ")
    }

    var tooltip: String {
        if snapshot.accounts.isEmpty { return "OneDrive: \(summary)" }
        return snapshot.accounts.map { "\($0.name): \($0.headline)" }.joined(separator: "\n")
    }

    var lidVerdict: LidVerdict {
        let accounts = snapshot.accounts
        if !snapshot.oneDriveRunning || accounts.contains(where: { $0.state == .notRunning }) { return .notRunning }
        if accounts.isEmpty { return .unknown("No OneDrive accounts found") }
        let failed = accounts.reduce(0) { $0 + $1.uploadsFailed }
        if failed > 0 { return .failing(failed) }
        let pending = accounts.reduce(0) { $0 + $1.uploadsPending }
        if pending > 0 { return .pending(pending) }
        if let blind = accounts.first(where: { !$0.uploadsCovered }) {
            return .unknown("Velum may have missed recent changes in \(blind.name)")
        }
        return .safe
    }

    func account(for key: String) -> AccountStatus? {
        snapshot.accounts.first { $0.config.key == key }
    }

    func start() {
        transfers.onChange = { [weak self] in self?.refresh() }
        uploadTracker.onChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
        }
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == oneDriveBundleID else { return }
                MainActor.assumeIsolated { self?.refresh(force: true) }
            })
        }
    }

    func refresh(force: Bool = false) {
        if inFlight {
            pending = true
            pendingForce = pendingForce || force
            return
        }
        inFlight = true
        let collector = self.collector
        let liveTransfers = transfers.snapshot()
        let tracker = uploadTracker
        queue.async {
            let next = collector.collect(force: force, transfers: liveTransfers, uploads: tracker.summary())
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.inFlight = false
                    if next != self.snapshot {
                        self.snapshot = next
                    }
                    self.onRefresh?(next)
                    let folders = Dictionary(next.accounts.map { ($0.config.key, $0.config.folder) },
                                             uniquingKeysWith: { first, _ in first })
                    self.transfers.watch(folders)
                    self.uploadTracker.watch(folders)
                    if self.pending {
                        let again = self.pendingForce
                        self.pending = false
                        self.pendingForce = false
                        self.refresh(force: again)
                    }
                }
            }
        }
    }
}

enum RelTime {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86400 { return "\(Int(s / 3600)) hr ago" }
        let days = Int(s / 86400)
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
