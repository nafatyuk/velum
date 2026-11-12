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
    /// Facts about the account itself, shown on their own line ("Desktop & Documents included · 1.27 TB free").
    var notes = ""
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
    /// Velum is watching this account's folders with no known gaps, so the counts above are complete.
    var uploadsCovered = false
    /// Work in flight that isn't a counted file: the provider's own queue, or transfers with no direction.
    var workPending = false
    /// Since when the provider's own queue has held work.
    var workingSince: Date?

    var id: String { config.key }
    var provider: ProviderID { config.provider }
}

/// The answer to "is it safe to close the lid?": is every local change in the cloud?
enum LidVerdict: Equatable {
    case safe
    case pending(Int)
    /// Nothing counted is waiting, but a service is still working on changes (its own queue).
    case busy(String)
    case failing(Int)
    /// A sync client isn't running (its name).
    case notRunning(String)
    case unknown(String)
}

/// A service present on this Mac, as of the last refresh.
struct ProviderStatus: Equatable {
    let id: ProviderID
    /// nil: no client app to run (iCloud).
    var clientRunning: Bool?
    /// A service-wide problem ("Storage full").
    var trouble: String?

    var isStopped: Bool { clientRunning == false }
}

struct Snapshot: Equatable {
    var accounts: [AccountStatus] = []
    var activity: [Activity] = []
    var providers: [ProviderStatus] = []
    var axTrusted = false
    var liveItemsFound = false

    var oneDrive: ProviderStatus? { providers.first { $0.id == .oneDrive } }
    var oneDriveRunning: Bool { oneDrive?.clientRunning == true }
    var stoppedProviders: [ProviderID] { providers.filter(\.isStopped).map(\.id) }

    /// "Is it safe to close the lid?", from live upload tracking only: a provider's hourly report can say
    /// "healthy" while a file is still waiting to go up.
    var lidVerdict: LidVerdict {
        if let stopped = providers.first(where: \.isStopped) { return .notRunning(stopped.id.name) }
        if providers.isEmpty { return .unknown("No cloud accounts found") }
        if let account = accounts.first(where: { $0.state == .notRunning }) { return .notRunning(account.provider.name) }
        if accounts.isEmpty {
            return .unknown("No \(providers.map(\.id.name).joined(separator: " or ")) accounts found")
        }
        let failed = accounts.reduce(0) { $0 + $1.uploadsFailed }
        if failed > 0 { return .failing(failed) }
        let pending = accounts.reduce(0) { $0 + $1.uploadsPending }
        if pending > 0 { return .pending(pending) }
        if let busy = accounts.first(where: \.workPending) { return .busy(busy.name) }
        if let blind = accounts.first(where: { !$0.uploadsCovered }) {
            return .unknown("Velum may have missed recent changes in \(blind.name)")
        }
        return .safe
    }
}

/// Gathers everything off the main thread. Only ever used from one serial queue.
final class Collector: @unchecked Sendable {
    let providers: [SyncProvider]

    /// Every service Velum knows. Each one shows only while it has a live account on this Mac.
    init(providers: [SyncProvider] = [OneDriveProvider(), ICloudProvider(), GoogleDriveProvider()]) {
        self.providers = providers
    }

    /// Where File Provider puts every service's folders. A change to it (an account added or removed)
    /// triggers rediscovery at once instead of within the minute.
    private let cloudStorage = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/CloudStorage").path
    private var cloudStorageStamp: Date?

    func collect(force: Bool, transfers: [String: TransferInfo] = [:], uploads: UploadsSnapshot = UploadsSnapshot()) -> Snapshot {
        let now = Date()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: cloudStorage))?[.modificationDate] as? Date
        let force = force || (cloudStorageStamp != nil && stamp != cloudStorageStamp)
        cloudStorageStamp = stamp
        var snapshot = Snapshot()
        var everything: [Activity] = []

        for provider in providers {
            let evidence = provider.gather(force: force, now: now)
            guard evidence.present else { continue }
            snapshot.providers.append(ProviderStatus(id: provider.id, clientRunning: evidence.clientRunning,
                                                     trouble: evidence.trouble))
            if provider.id == .oneDrive {
                snapshot.axTrusted = evidence.axTrusted
                snapshot.liveItemsFound = evidence.liveItemsFound
            }
            everything += evidence.activity
            for var account in evidence.accounts {
                let key = account.config.key
                if !account.config.keepsOwnHistory {
                    let seen = uploads.completed.filter { $0.accountKey == key }
                    everything += seen
                    account.lastActivity = account.lastActivity ?? seen.map(\.date).max()
                }
                snapshot.accounts.append(Self.status(
                    account, transfer: transfers[key], uploads: uploads.accounts[key],
                    watchingUploads: uploads.watching.contains(key), now: now
                ))
            }
        }
        everything.sort { $0.date > $1.date }
        snapshot.activity = Array(everything.prefix(25))
        return snapshot
    }

    /// Status sources, most authoritative first, the same order for every provider: the client's own
    /// words (OneDrive's icon text, only readable while its icons exist), live File Provider state (changed
    /// files' upload flags and transfer progress), then the provider's periodic report. With no evidence
    /// the state is `.unknown`, never "Up to date".
    static func status(_ account: AccountEvidence, transfer: TransferInfo?, uploads: UploadSummary?,
                       watchingUploads: Bool, now: Date) -> AccountStatus {
        let config = account.config
        let report = account.report
        var state = SyncState.unknown
        var headline = "No status yet"
        var source = ""
        var extra: [String] = []
        var working = false

        let failed = uploads?.failed ?? []
        let uploading = max(uploads?.uploading ?? 0, transfer?.uploadingFiles ?? 0)
        let downloading = transfer?.downloadingFiles ?? 0
        let moving = uploading + downloading
        // Direction-less per-file progress: OneDrive publishes two objects per uploaded file, so it only
        // says "something is moving", never how many.
        let unlabelled = (transfer?.otherFiles ?? 0) > 0
        let waiting = uploads?.waiting ?? 0
        func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

        if !account.running {
            state = .notRunning
            headline = "Not running, so nothing is syncing"
        } else if let exact = account.exactStatus, !exact.isEmpty {
            state = SyncState.classify(exact)
            headline = exact
            source = "From \(config.provider.name)"
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
            let paused = report?.state == .paused
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
            working = true
        } else if let report {
            working = report.state == .syncing
            state = report.state
            headline = report.headline
            source = report.source
            if report.state == .ok {
                // A healthy report plus, when Velum is watching with no gaps, nothing pending right now.
                let liveCoverage = watchingUploads && uploads?.coverageGap != true
                if liveCoverage { source = "Nothing pending · \(report.source)" }
            }
        }

        var details = extra
        if !source.isEmpty { details.append(source) }
        if let last = account.lastActivity { details.append("last activity \(RelTime.string(last, now: now))") }

        var status = AccountStatus(config: config, name: account.name, state: state, headline: headline,
                                   detail: details.joined(separator: " · "), source: source, pid: account.pid,
                                   isLive: account.exactStatus != nil, lastActivity: account.lastActivity)
        status.notes = account.notes.joined(separator: " · ")
        status.uploadsPending = (uploads?.waiting ?? 0) + uploading
        status.uploadsFailed = failed.count
        status.firstFailure = failed.first
        status.oldestWaiting = uploads?.oldestWaiting
        status.uploadsCovered = account.running && watchingUploads && uploads?.coverageGap != true
        status.workPending = account.running && working
        status.workingSince = working ? account.workingSince : nil
        return status
    }
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published var loginItemEnabled = false
    /// The tallest the panel may be (the screen's height under the menu bar); set by the shell.
    @Published var maxPanelHeight: CGFloat = 10_000
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

    /// The panel's title and the name VoiceOver gives the icon: the service's own name while there is only
    /// one, "Cloud Sync" once there are several.
    var title: String { "Cloud Sync" }

    /// Several services on this Mac: VoiceOver names the service with each account.
    var groupsByService: Bool { snapshot.providers.count > 1 }

    /// Many accounts: healthy rows shrink to one line.
    var compactRows: Bool { snapshot.accounts.count > 6 }

    var overallState: SyncState {
        if snapshot.providers.isEmpty { return .unknown }
        // The worst of every account and every stopped client: a stopped OneDrive mustn't hide a failing upload.
        let stopped: [SyncState] = snapshot.stoppedProviders.isEmpty ? [] : [.notRunning]
        return (snapshot.accounts.map(\.state) + stopped).max() ?? .ok
    }

    var summary: String {
        if snapshot.accounts.isEmpty {
            if let stopped = snapshot.stoppedProviders.first { return "\(stopped.name) isn’t running" }
            return "No cloud accounts found"
        }
        let attention = snapshot.accounts.filter { $0.state != .ok }
        if attention.isEmpty {
            switch snapshot.accounts.count {
            case 1: return "Up to date"
            case 2: return "Both accounts are up to date"
            default: return "Everything is up to date"
            }
        }
        if attention.count > 2 {
            return "\(attention.count) of \(snapshot.accounts.count) accounts need attention"
        }
        return attention.map { "\($0.name): \($0.headline)" }.joined(separator: " · ")
    }

    /// Read by VoiceOver on the menu bar icon: one sentence per account, or with many accounts only the
    /// ones needing attention plus how many are up to date.
    var accessibilitySummary: String {
        if snapshot.accounts.isEmpty { return "\(title): \(summary)" }
        return "\(title). " + listed.map { "\(spokenName($0)): \($0.headline)." }.joined(separator: " ") + restLine(". ")
    }

    var tooltip: String {
        if snapshot.accounts.isEmpty { return "\(title): \(summary)" }
        return (listed.map { "\($0.name): \($0.headline)" } + [restLine("")].filter { !$0.isEmpty }).joined(separator: "\n")
    }

    private var listed: [AccountStatus] {
        compactRows ? snapshot.accounts.filter { $0.state != .ok } : snapshot.accounts
    }

    private func restLine(_ prefix: String) -> String {
        let rest = snapshot.accounts.count - listed.count
        guard rest > 0 else { return "" }
        return prefix + (rest == 1 ? "1 account up to date" : "\(rest) accounts up to date")
    }

    /// "OneDrive, School" once several services share the panel; the name alone otherwise.
    func spokenName(_ account: AccountStatus) -> String {
        guard groupsByService, !account.name.hasPrefix(account.provider.name) else { return account.name }
        return "\(account.provider.name), \(account.name)"
    }

    var lidVerdict: LidVerdict { snapshot.lidVerdict }

    /// For `Velum --render-panel`: shows a snapshot without starting the live sources.
    func show(_ snapshot: Snapshot) {
        self.snapshot = snapshot
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
                let clients = Set(ProviderID.allCases.compactMap(\.clientBundleID))
                guard let id = app?.bundleIdentifier, clients.contains(id) else { return }
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
                    let roots = Dictionary(next.accounts.map { ($0.config.key, $0.config.watchRoots) },
                                           uniquingKeysWith: { first, _ in first })
                    self.transfers.watch(roots)
                    self.uploadTracker.watch(roots, recordingUploadsFor: Set(next.accounts.filter { !$0.config.keepsOwnHistory }.map(\.id)))
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
