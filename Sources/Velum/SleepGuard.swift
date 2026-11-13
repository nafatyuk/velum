import AppKit

/// Card A5: a note when files weren't in the cloud as the Mac went to sleep, logged out, restarted or shut down.
/// It's the "you left your lights on" chime: it warns, and never holds up or delays sleep or shutdown, and it
/// changes no power settings.
///
/// What macOS 27 lets an ordinary app do (its SDK headers and Apple's QA1340):
/// - `willSleepNotification` (lid closed, Apple menu → Sleep, idle sleep) is notice only, and sleep goes ahead. A
///   slow handler can hold sleep up to 30 s, so this one reads only what Velum already holds and returns. Only idle
///   sleep can be refused (IOKit), and Velum doesn't refuse it.
/// - A note posted as the Mac falls asleep isn't seen, so the news waits for `didWakeNotification`, and then for
///   the screen to be unlocked: Velum's own banner (unsigned builds, card A2) can't show over the lock screen.
/// - `willPowerOffNotification` (log out, restart, shut down) comes just before apps are asked to quit, about a
///   second later; `extendPowerOffBy:` isn't implemented. The alert goes out at once, and what wasn't in the cloud
///   is saved, so the next launch can say whether it made it.
///
/// Every service is covered: files come from the upload tracker's listing (card A3), by path, and Google Drive's own
/// queue from the account rows. A file counts as in the cloud only when macOS's upload flag says so, never just
/// because it left the list (it may have been deleted or moved). The note follows A2's rules: the alerts toggle,
/// one problem note, one follow-up when it clears, and A2's own stuck alert waits while this note covers the same
/// files (`SleepGuardCover`).
@MainActor
final class SleepGuard {
    static let shared = SleepGuard()

    /// What wasn't in the cloud at a sleep or a shutdown, and what has been said about it. Saved in Velum's
    /// defaults (the paths stay on this Mac, like the upload tracker's own), so a shutdown, a quit, or a Mac that
    /// ran flat while asleep gets its check at the next launch.
    struct Watch: Codable, Equatable {
        enum Moment: String, Codable { case sleep, powerOff }
        var moment: Moment
        var at: Date
        /// Files on their way up (waiting or uploading; not failing, which A2 has already reported): path → account key.
        var files: [String: String] = [:]
        /// Accounts whose service had work queued that Velum can't count by file (Google Drive's own queue).
        var queues: Set<String> = []
        /// Each account's service, for the wording.
        var services: [String: ProviderID] = [:]
        /// Paths and queues (`queue:<key>`) the problem note has named, so it isn't said twice.
        var reported: Set<String> = []

        var isEmpty: Bool { files.isEmpty && queues.isEmpty }

        /// A second sleep (or a shutdown) before the last check finished: one story, not two.
        mutating func merge(_ earlier: Watch) {
            files.merge(earlier.files) { new, _ in new }
            queues.formUnion(earlier.queues)
            services.merge(earlier.services) { new, _ in new }
            reported.formUnion(earlier.reported)
        }
    }

    /// Where a followed file or queue stands now.
    enum Fate: Equatable {
        /// In the cloud: macOS's upload flag says so (for a queue, the service's own live "Up to date").
        case cleared
        /// Still not in the cloud. `moving`: uploading, or a queue at work.
        case still(moving: Bool)
        /// Its app isn't running, so it can't move. A2 speaks for a stopped app.
        case waitingOnApp
        /// Off the list, but with no upload flag to show for it.
        case unsure
        /// No longer this note's business: failing now (A2's alert), deleted or moved, or its account is gone.
        case dropped

        var isStill: Bool {
            if case .still = self { return true }
            return false
        }
    }

    /// A file's state as macOS reports it, checked only once it has left the tracker's list.
    enum Where { case inCloud, gone, unknown }

    struct Words: Equatable {
        let title: String
        let body: String
        /// The body without file names, for the debug log.
        let logged: String
    }

    /// What the guard reads and where it speaks; `start` wires these to the store and the notifier, tests to stand-ins.
    struct Sources {
        var snapshot: @MainActor () -> Snapshot
        var pending: @MainActor () -> PendingList
        var alertsOn: @MainActor () -> Bool
        var post: @MainActor (_ words: Words, _ isProblem: Bool) -> Void
        var cover: @MainActor (SleepGuardCover) -> Void
        var screenLocked: @MainActor () -> Bool = { SleepGuard.screenIsLocked() }
        var whereIs: @MainActor (String) -> Where = { SleepGuard.whereIs($0) }
    }

    /// How long after unlock, with nothing moving or clearing, before "still not in the cloud". A file that is
    /// uploading, or a count that's falling, waits up to `UploadTracker.stuckAfter` (Fable).
    static let wait: TimeInterval = 2 * 60
    /// Still running this long after a log out or shutdown began: it was cancelled.
    static let powerOffCancelled: TimeInterval = 2 * 60
    static let defaultsKey = "sleepGuardWatch"
    /// The alerts' identifier (`velum.sleep`), so a follow-up replaces the problem it answers.
    static let alertKey = "sleep"
    /// File Provider lookups per check, for files that have left the list.
    private static let lookupBudget = 50

    private let defaults: UserDefaults
    private let clock: () -> Date
    /// The longest wait while something is moving: A2's stuck threshold (`UploadTracker.stuckAfter`).
    private let stuckAfter: () -> TimeInterval
    private var sources: Sources?
    private var observers: [NSObjectProtocol] = []

    private(set) var watch: Watch?
    /// Checking since a wake or a launch; nil while asleep, shutting down, or with nothing to follow.
    private(set) var awakeSince: Date?
    private var launched = false
    private var unlockedAt: Date?
    private var lastProgress: Date?
    private var lastStill: Int?
    /// Paths already seen in the cloud this check, so they aren't looked up again.
    private var confirmed: Set<String> = []
    /// After a note, the notifier keeps the cover for that same refresh, so A2's "resolved" isn't said twice.
    private var coverLingers = false

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         stuckAfter: @escaping () -> TimeInterval = { UploadTracker.stuckAfter }) {
        self.defaults = defaults
        self.clock = clock
        self.stuckAfter = stuckAfter
    }

    /// Starts listening; one line in AppDelegate, after the notifier is set up. Each refresh checks first, then
    /// the notifier sees the same snapshot with what this note covers.
    func start(store: Store, notifier: Notifier) {
        connect(Sources(snapshot: { store.snapshot },
                        pending: { store.pendingFiles() },
                        alertsOn: { store.notificationsEnabled },
                        post: { words, isProblem in
                            notifier.note(Self.alertKey, title: words.title, body: words.body, isProblem: isProblem, logged: words.logged)
                        },
                        cover: { notifier.sleepGuard = $0 }),
                center: NSWorkspace.shared.notificationCenter, queue: .main)
        let notifierUpdate = store.onRefresh
        store.onRefresh = { [weak self] snapshot in
            self?.tick()
            notifierUpdate?(snapshot)
        }
    }

    /// Listens on `center` (NSWorkspace's, or a stand-in) and picks up a check saved before a shutdown or quit.
    func connect(_ sources: Sources, center: NotificationCenter, queue: OperationQueue?) {
        self.sources = sources
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.willPowerOffNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: queue) { [weak self] note in
                let name = note.name
                MainActor.assumeIsolated { self?.handle(name) }
            })
        }
        resume()
    }

    private func handle(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification: willSleep()
        case NSWorkspace.didWakeNotification: didWake()
        case NSWorkspace.willPowerOffNotification: willPowerOff()
        default: break
        }
    }

    // MARK: The three moments

    /// Records what isn't in the cloud and returns at once. Nothing is said now: it wouldn't be seen.
    func willSleep() {
        guard let sources else { return }
        let snapshot = sources.snapshot()
        var next = Self.outstanding(.sleep, at: clock(), snapshot: snapshot, pending: sources.pending())
        if let open = watch { next.merge(open) }
        reset()
        launched = false
        debugLog("sleep", "Sleep · lid: \(snapshot.lidVerdict) · \(next.isEmpty ? "nothing on its way up" : Self.describe(next))")
        save(next.isEmpty ? nil : next)
        sources.cover(next.isEmpty ? SleepGuardCover() : Self.cover(next, fates: [:]))
    }

    func didWake() {
        guard let watch else {
            debugLog("sleep", "Wake · nothing was on its way up at sleep")
            return
        }
        reset()
        awakeSince = clock()
        debugLog("sleep", "Wake · following \(Self.describe(watch))")
    }

    /// The alert goes out at once (it's on screen for about a second), and the list is saved for the next launch.
    func willPowerOff() {
        guard let sources else { return }
        let snapshot = sources.snapshot()
        var next = Self.outstanding(.powerOff, at: clock(), snapshot: snapshot, pending: sources.pending())
        debugLog("sleep", "Log out, restart or shut down · lid: \(snapshot.lidVerdict) · \(next.isEmpty ? "nothing on its way up" : Self.describe(next))")
        if !next.isEmpty { say(Self.powerOffWords(next), problem: true) }
        if let open = watch { next.merge(open) }
        reset()
        save(next.isEmpty ? nil : next)
    }

    // MARK: Checking after a wake or a launch

    /// Runs with every refresh, before the notifier's update.
    func tick() {
        guard let sources else { return }
        if coverLingers {
            coverLingers = false
            sources.cover(SleepGuardCover())
        }
        guard var watch else { return }
        let now = clock()
        guard awakeSince != nil else {
            if watch.moment == .powerOff, now.timeIntervalSince(watch.at) > Self.powerOffCancelled {
                debugLog("sleep", "Still running after a log out or shutdown began: it was cancelled, so the next launch has nothing to report")
                finish(noted: false)
            }
            return
        }
        let snapshot = sources.snapshot()
        guard !snapshot.providers.isEmpty else { return }     // a launch's first refresh hasn't come in yet
        let pending = sources.pending()
        let fates = Self.fates(watch, snapshot: snapshot, pending: pending, confirmed: &confirmed, whereIs: sources.whereIs)
        sources.cover(Self.cover(watch, fates: fates))

        if unlockedAt == nil {
            guard !sources.screenLocked() else { return }       // Velum's banner can't show over the lock screen
            unlockedAt = now
            lastProgress = now
        }
        let still = Set(fates.filter { $0.value.isStill }.keys)
        if let last = lastStill, still.count < last { lastProgress = now }
        lastStill = still.count

        let open = fates.filter { $0.value != .cleared && $0.value != .dropped }
        if open.isEmpty {
            conclude(watch, fates: fates)
            return
        }

        let elapsed = now.timeIntervalSince(unlockedAt ?? now)
        let moving = fates.values.contains(.still(moving: true))
        let capped = elapsed >= stuckAfter()
        let quiet = elapsed >= Self.wait && now.timeIntervalSince(lastProgress ?? now) >= Self.wait && !moving
        guard quiet || capped else { return }

        if still.isEmpty {
            // Left: files whose app isn't running (A2 speaks for it), or ones Velum can't vouch for either way.
            guard capped || !open.values.contains(.unsure) else { return }
            debugLog("sleep", "After \(watch.moment == .sleep ? "sleep" : "the last log out or shutdown") · nothing to say: \(Self.tally(fates))")
            finish(noted: false)
            return
        }
        guard !still.subtracting(watch.reported).isEmpty else { return }   // already said; the follow-up comes when they clear

        let files = still.filter { watch.files[$0] != nil }
        let first = pending.files.first { files.contains($0.path) && !$0.isFailing }.map { Notifier.shortName($0.name) }
        say(Self.problemWords(first: first, files: files.count, queues: Self.services(still, in: watch),
                              moment: watch.moment, launched: launched), problem: true)
        watch.reported.formUnion(still)
        save(watch)
    }

    /// Everything followed has an answer: one resolved note, a follow-up to the problem note, or nothing.
    private func conclude(_ watch: Watch, fates: [String: Fate]) {
        let cleared = Set(fates.filter { $0.value == .cleared }.keys)
        let files = cleared.filter { watch.files[$0] != nil }.count
        if watch.reported.isEmpty {
            guard !cleared.isEmpty else {
                debugLog("sleep", "After \(watch.moment == .sleep ? "sleep" : "the last log out or shutdown") · nothing to say: \(Self.tally(fates))")
                finish(noted: false)
                return
            }
            say(Self.resolvedWords(files: files, queues: Self.services(cleared, in: watch), moment: watch.moment), problem: false)
            finish(noted: true)
        } else if watch.reported.allSatisfy({ fates[$0] == .cleared }) {
            let reportedFiles = watch.reported.filter { watch.files[$0] != nil }.count
            say(Self.followUpWords(files: reportedFiles, queues: Self.services(watch.reported, in: watch), moment: watch.moment),
                problem: false)
            finish(noted: true)
        } else {
            // Gone isn't resolved (A2's rule): a reported file was deleted, moved, or is failing now.
            debugLog("sleep", "After the problem note · no follow-up: \(Self.tally(fates))")
            finish(noted: false)
        }
    }

    private func say(_ words: Words, problem: Bool) {
        guard let sources else { return }
        if sources.alertsOn() {
            sources.post(words, problem)
        } else {
            debugLog("sleep", "Alerts are off, so not shown: \(words.title) · \(words.logged)")
        }
    }

    private func reset() {
        awakeSince = nil
        unlockedAt = nil
        lastProgress = nil
        lastStill = nil
        confirmed = []
        coverLingers = false
    }

    private func finish(noted: Bool) {
        save(nil)
        reset()
        if noted { coverLingers = true } else { sources?.cover(SleepGuardCover()) }
    }

    private func save(_ next: Watch?) {
        watch = next
        if let next, let data = try? JSONEncoder().encode(next) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// A check saved before a shutdown or a quit runs as if the Mac had just woken.
    private func resume() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(Watch.self, from: data) else { return }
        watch = saved
        reset()
        awakeSince = clock()
        launched = true
        debugLog("sleep", "Launch · following \(Self.describe(saved)) from before the last \(saved.moment == .sleep ? "sleep" : "log out or shutdown")")
        sources?.cover(Self.cover(saved, fates: [:]))
    }

    // MARK: Evidence

    /// What isn't in the cloud right now: files on their way up, by path, and services with work queued.
    nonisolated static func outstanding(_ moment: Watch.Moment, at: Date, snapshot: Snapshot, pending: PendingList) -> Watch {
        var watch = Watch(moment: moment, at: at)
        for file in pending.files where !file.isFailing { watch.files[file.path] = file.account }
        watch.queues = Set(snapshot.accounts.filter(\.workPending).map(\.id))
        let involved = Set(watch.files.values).union(watch.queues)
        for account in snapshot.accounts where involved.contains(account.id) { watch.services[account.id] = account.provider }
        return watch
    }

    nonisolated static func queueID(_ account: String) -> String { "queue:" + account }

    /// Each followed file's and queue's fate, keyed by path or `queue:<key>`.
    static func fates(_ watch: Watch, snapshot: Snapshot, pending: PendingList, confirmed: inout Set<String>,
                      whereIs: @MainActor (String) -> Where) -> [String: Fate] {
        let listed = Dictionary(pending.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let accounts = Dictionary(snapshot.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stopped = Set(snapshot.stoppedProviders)
        func appRunning(_ account: AccountStatus) -> Bool { account.state != .notRunning && !stopped.contains(account.provider) }

        var fates: [String: Fate] = [:]
        var lookups = 0
        for (path, key) in watch.files {
            if let file = listed[path] {
                if file.isFailing { fates[path] = .dropped }
                else if let account = accounts[key], !appRunning(account) { fates[path] = .waitingOnApp }
                else if accounts[key] == nil { fates[path] = .dropped }
                else { fates[path] = .still(moving: file.status == .uploading) }
            } else if confirmed.contains(path) {
                fates[path] = .cleared
            } else if lookups < lookupBudget {
                lookups += 1
                switch whereIs(path) {
                case .inCloud:
                    confirmed.insert(path)
                    fates[path] = .cleared
                case .gone:
                    fates[path] = .dropped
                case .unknown:
                    fates[path] = accounts[key] == nil ? .dropped : .unsure
                }
            } else {
                fates[path] = .unsure     // looked up at a later check
            }
        }
        for key in watch.queues {
            guard let account = accounts[key] else { fates[queueID(key)] = .dropped; continue }
            if !appRunning(account) { fates[queueID(key)] = .waitingOnApp }
            else if account.workPending { fates[queueID(key)] = .still(moving: true) }
            // Only the service's own live "Up to date" (Google Drive's empty queue) clears it, never an old report.
            else if account.state == .ok && account.age == "live" { fates[queueID(key)] = .cleared }
            else { fates[queueID(key)] = .unsure }
        }
        return fates
    }

    /// What the notifier holds back while this note covers it: every followed file and queue not dropped.
    nonisolated static func cover(_ watch: Watch, fates: [String: Fate]) -> SleepGuardCover {
        var cover = SleepGuardCover()
        for (path, key) in watch.files where fates[path] != .dropped {
            cover.files.insert(path)
            cover.accounts.insert(key)
        }
        for key in watch.queues where fates[queueID(key)] != .dropped { cover.queues.insert(key) }
        return cover
    }

    /// The services of the queues among `items`, in Velum's order.
    nonisolated static func services(_ items: Set<String>, in watch: Watch) -> [ProviderID] {
        let keys = watch.queues.filter { items.contains(queueID($0)) }
        return ordered(keys.map { watch.services[$0] ?? .googleDrive })
    }

    nonisolated static func ordered(_ services: [ProviderID]) -> [ProviderID] {
        ProviderID.allCases.filter { services.contains($0) }
    }

    nonisolated static func screenIsLocked() -> Bool {
        // No session to ask: can't tell, so don't hold the note back (Fable).
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if session["kCGSSessionOnConsoleKey"] as? Bool == false { return true }   // another user's session is in front
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }

    nonisolated static func whereIs(_ path: String) -> Where {
        guard FileManager.default.fileExists(atPath: path) else { return .gone }
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.ubiquitousItemIsUploadedKey])
        return values?.ubiquitousItemIsUploaded == true ? .inCloud : .unknown
    }

    // MARK: Words (Codex and the Fable consultant; see the card's hand-off)

    nonisolated private static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    nonisolated private static func names(_ services: [ProviderID]) -> String {
        let names = services.map(\.name)
        return names.count <= 2 ? names.joined(separator: " and ")
                                : names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    nonisolated private static func when(_ moment: Watch.Moment) -> String {
        moment == .sleep ? "when your Mac slept" : "when you last shut down or logged out"
    }

    /// "3 files weren’t in the cloud when your Mac slept. They’re there now."
    nonisolated static func resolvedWords(files n: Int, queues: [ProviderID], moment: Watch.Moment) -> Words {
        if n > 0 || queues.isEmpty {
            let body = n == 1 ? "1 file wasn’t in the cloud \(when(moment)). It’s there now."
                              : "\(n) files weren’t in the cloud \(when(moment)). They’re there now."
            return Words(title: moment == .sleep ? "Uploaded after sleep" : "Uploaded since shutdown", body: body, logged: body)
        }
        let one = queues.count == 1
        let body = "\(names(queues)) \(one ? "was" : "were") still syncing changes \(when(moment)). \(one ? "It has" : "They have") caught up."
        return Words(title: "\(names(queues)) caught up", body: body, logged: body)
    }

    /// "Report.docx and 2 more haven’t uploaded since your Mac woke." Names the oldest file; the log gets the count.
    nonisolated static func problemWords(first: String?, files n: Int, queues: [ProviderID], moment: Watch.Moment,
                                         launched: Bool) -> Words {
        let since = moment == .powerOff ? "since you last shut down or logged out"
                  : launched ? "since your Mac slept" : "since your Mac woke"
        if n > 0 || queues.isEmpty {
            let counted = n == 1 ? "1 file hasn’t uploaded \(since)." : "\(n) files haven’t uploaded \(since)."
            let body = first.map { n == 1 ? "\($0) hasn’t uploaded \(since)." : "\($0) and \(n - 1) more haven’t uploaded \(since)." }
            return Words(title: "Still not in the cloud", body: body ?? counted, logged: counted)
        }
        let one = queues.count == 1
        let body = one ? "It hasn’t finished the changes it had queued \(when(moment))."
                       : "They haven’t finished the changes they had queued \(when(moment))."
        return Words(title: "\(names(queues)) \(one ? "is" : "are") still syncing", body: body, logged: body)
    }

    /// The one follow-up to a problem note, once everything it named is in the cloud. It replaces that note.
    nonisolated static func followUpWords(files n: Int, queues: [ProviderID], moment: Watch.Moment) -> Words {
        let before = moment == .sleep ? "before your Mac slept" : "before you last shut down or logged out"
        if n > 0 || queues.isEmpty {
            let body = n == 1 ? "The file from \(before) is in the cloud now." : "The files from \(before) are in the cloud now."
            return Words(title: "Uploads: resolved", body: body, logged: body)
        }
        let one = queues.count == 1
        let body = "\(one ? "It has" : "They have") finished the changes \(one ? "it" : "they") had queued \(when(moment))."
        return Words(title: "\(names(queues)): resolved", body: body, logged: body)
    }

    /// "3 files aren’t in the cloud yet. They’ll upload the next time OneDrive runs." (the card's wording).
    nonisolated static func powerOffWords(_ watch: Watch) -> Words {
        let n = watch.files.count
        let queues = services(Set(watch.queues.map(queueID)), in: watch)
        guard n > 0 else {
            let one = queues.count == 1
            let body = "Some changes aren’t in the cloud yet. \(names(queues)) will carry on the next time \(one ? "it runs" : "they run")."
            return Words(title: "\(names(queues)) \(one ? "hasn’t" : "haven’t") finished", body: body, logged: body)
        }
        let apps = ordered(Set(watch.files.values).compactMap { watch.services[$0] } + queues)
        // iCloud is part of macOS, with no app to "run"; three services read better as a time than a list.
        let later = apps.isEmpty || apps.contains { $0.clientBundleID == nil } || apps.count > 2   // C3: other cloud folders name no one app
            ? "after you log in again"
            : "the next time \(names(apps)) \(apps.count == 1 ? "runs" : "run")"
        let body = n == 1 ? "1 file isn’t in the cloud yet. It’ll upload \(later)."
                          : "\(n) files aren’t in the cloud yet. They’ll upload \(later)."
        return Words(title: "Not in the cloud yet", body: body, logged: body)
    }

    // MARK: Debug log (counts and services, never file names)

    nonisolated static func describe(_ watch: Watch) -> String {
        var parts: [String] = []
        if !watch.files.isEmpty {
            let byService = Dictionary(grouping: watch.files.values) { watch.services[$0]?.name ?? "another service" }
                .map { "\($0.key) \($0.value.count)" }.sorted()
            parts.append("\(files(watch.files.count)) on the way up (\(byService.joined(separator: ", ")))")
        }
        if !watch.queues.isEmpty {
            parts.append("\(names(services(Set(watch.queues.map(queueID)), in: watch))) still syncing changes")
        }
        if !watch.reported.isEmpty { parts.append("\(watch.reported.count) already in a problem note") }
        return parts.joined(separator: " · ")
    }

    nonisolated private static func tally(_ fates: [String: Fate]) -> String {
        var counts: [String: Int] = [:]
        for fate in fates.values {
            let name = switch fate {
            case .cleared: "in the cloud"
            case .still: "still waiting"
            case .waitingOnApp: "waiting on a stopped app"
            case .unsure: "can’t vouch"
            case .dropped: "failing, deleted, moved or gone"
            }
            counts[name, default: 0] += 1
        }
        return counts.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", ")
    }
}

/// What the sleep guard's note covers, for the notifier (card A5), so the user isn't told twice.
struct SleepGuardCover: Equatable {
    /// Paths it follows. An account's stuck alert waits while every file it's stuck on is one of these, so a new
    /// file stuck in the same account still alerts (Codex and Fable).
    var files: Set<String> = []
    /// Accounts whose queue it follows: their "changes are stuck" alert, and its "resolved", wait.
    var queues: Set<String> = []
    /// Accounts it follows files in: their stuck alert's "resolved" is its note's to give.
    var accounts: Set<String> = []
}
