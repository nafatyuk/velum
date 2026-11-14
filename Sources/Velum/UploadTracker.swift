import CoreServices
import Foundation

/// Uploads in flight for one account: local changes macOS hasn't finished sending to OneDrive.
struct UploadSummary: Equatable {
    var uploading = 0
    var waiting = 0
    var failed: [String] = []      // "<file name>: <reason>"
    var oldestWaiting: Date?
    /// FSEvents may have missed changes (dropped events, a resume point too old to replay, too many files),
    /// so "nothing pending" isn't proof right now. Only a finished re-check of the account's folders ends it.
    var coverageGap = false
    /// When Velum may have started missing changes (the reason line says so).
    var coverageGapSince: Date?
    /// What ends the gap: the re-check, under way or failed.
    var coverageCheck: CoverageCheck?
    /// The gap is Velum's first look: no re-check has finished walking all of the account's folders yet (a new
    /// install, an install from before re-checks, a newly added folder), so files already stuck are unknown.
    var coverageFirstLook = false
}

/// The re-check that ends a coverage gap: a walk of the account's folders asking File Provider about every file.
enum CoverageCheck: Equatable {
    /// Under way, or about to start.
    case checking
    /// The last re-check couldn't finish; the gap stays, and Velum tries again at `retry`.
    case failed(RecheckFailure, retry: Date)
}

/// Why a re-check couldn't finish.
enum RecheckFailure: Equatable {
    /// The folders hold more files than one re-check looks at.
    case tooManyFiles(Int)
    /// More files are out of the cloud than the tracker can hold.
    case tooManyPending(Int)
    /// A folder couldn't be read, or is gone.
    case unreadable
}

/// What the tracker knows right now: which accounts it watches, what's still pending in each, and the
/// uploads it saw finish in accounts whose service keeps no history of its own (iCloud).
struct UploadsSnapshot: Equatable {
    var watching: Set<String> = []
    var accounts: [String: UploadSummary] = [:]
    var completed: [Activity] = []
}

/// A file that hasn't reached the cloud: the panel's "Not in the cloud yet" list, the stuck alert's file name.
struct PendingFile: Equatable, Identifiable {
    enum Status: Equatable {
        /// Not started yet, or the service hasn't said.
        case waiting
        case uploading
        /// The service's reason, as macOS words it, without the file name.
        case failed(String)
    }

    let account: String     // the account's key
    let path: String
    /// When its latest change happened.
    let since: Date
    let status: Status

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isFailing: Bool { if case .failed = status { true } else { false } }
}

/// Files listed by `UploadTracker.pending` (failing first, then oldest first; capped), plus how many
/// qualified in all and per account, listed or not.
struct PendingList: Equatable {
    var files: [PendingFile] = []
    var total = 0
    var perAccount: [String: Int] = [:]
}

/// Watches each account's folders for changed files (FSEvents) and asks File Provider where each one is
/// (`ubiquitousItemIsUploaded`, `…IsUploading`, `…UploadingError`). OneDrive and iCloud keep those flags
/// honest: a changed file reads "not uploaded" at once, "uploading" when the upload starts, and "uploaded"
/// within a second or two of the service's own record. Public APIs, no permission needed, and unlike
/// OneDrive's icon text it keeps working after OneDrive restarts with its icons hidden.
///
/// When FSEvents may have missed changes, the account has a coverage gap, and Velum can't vouch for "nothing
/// pending" until a re-check has walked its folders and fed every file File Provider says isn't in the cloud
/// into the pending files. Only a finished re-check ends a gap; no timer does. FSEvents only reports changes, so
/// a folder no re-check has walked yet starts with a gap too: Velum's first look at it.
///
/// Pending files, open gaps, the folders already looked through and the FSEvents resume point are saved, so a
/// quit or restart doesn't lose track.
final class UploadTracker: @unchecked Sendable {
    private final class Stream {
        let key: String
        let roots: [URL]
        var ref: FSEventStreamRef?
        weak var tracker: UploadTracker?

        init(key: String, roots: [URL], tracker: UploadTracker) {
            self.key = key
            self.roots = roots
            self.tracker = tracker
        }
    }

    /// Internal (not private) so tests can seed a stand-in tracker's saved state.
    enum State: Codable, Equatable {
        case unchecked, waiting, uploading
        case failed(String)     // "<file name>: <reason>"
    }

    struct Candidate: Codable {
        let account: String
        var since: Date
        var generation: Int     // bumped on every change, so a check never erases newer work
        var state: State
        var checked: Date
    }

    /// A stretch where FSEvents may have missed changes in one account. Only a finished re-check of the
    /// account's folders ends it; a loss during the re-check needs another one.
    private struct Gap {
        enum Check {
            /// Starts then: a few seconds after the latest loss, so a burst of them settles first.
            case due(Date)
            case running
            case failed(RecheckFailure, retry: Date)
        }

        var since: Date
        /// Bumped on every loss, so a re-check that started earlier never ends a newer gap.
        var generation = 1
        var check: Check

        func isDue(_ now: Date) -> Bool {
            switch check {
            case .due(let at), .failed(_, let at): at <= now
            case .running: false
            }
        }

        var dueDate: Date {
            switch check {
            case .due(let at), .failed(_, let at): at
            case .running: .distantFuture
            }
        }
    }

    private let queue = DispatchQueue(label: "Velum.fsevents", qos: .utility)
    private let recheckQueue = DispatchQueue(label: "Velum.recheck", qos: .utility)
    private let lock = NSLock()
    // Guarded by lock:
    private var candidates: [String: Candidate] = [:]
    private var watching: Set<String> = []
    private var roots: [String: [URL]] = [:]
    private var gaps: [String: Gap] = [:]
    /// Per account, the folders the last finished re-check walked. A watched folder not in it gets a first look.
    private var looked: [String: Set<String>] = [:]
    private var gapsDirty = false       // gaps or looked
    private var rechecking = false
    private var dirty = false
    private var completedDirty = false
    private var checkpoint: (id: FSEventStreamEventId, taken: Date)?
    private var recordUploads: Set<String> = []
    private var completed: [Activity] = []
    private var uploadedCount: [String: Int] = [:]   // A6: uploads seen to finish per account since launch
    // Main thread only:
    private var streams: [String: Stream] = [:]

    private let defaults: UserDefaults
    private let inspector: @Sendable (String) -> Outcome
    private let pendingKey = "pendingUploads"
    private let completedKey = "recentUploads"
    private let gapsKey = "coverageGaps"
    private let lookedKey = "coverageLooked"
    private let completedLimit = 30
    private let inspectBudget = 400                 // File Provider lookups per refresh (each takes about 3 ms)
    private let maxReplay: TimeInterval = 86_400    // don't replay more than a day of change history
    private let checkpointEvery: TimeInterval = 10 * 60
    private let recheckSettle: TimeInterval = 5     // after the latest loss, before a re-check starts
    private let recheckRetry: TimeInterval = 30 * 60
    // Internal (not private) so tests can lower them:
    var maxCandidates = 5000
    /// File Provider lookups one re-check may make. Past it the gap stays. Measured November 13: an iCloud Drive
    /// with Desktop and Documents took about 78,000 lookups in 12 minutes at the walk's pace, so this is room
    /// for about 6 times that, a little over an hour in the background.
    var recheckLimit = 500_000
    /// Tests run re-checks synchronously, on the thread that calls `summary`.
    var rechecksInline = false

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey, .ubiquitousItemIsExcludedFromSyncKey,
    ]

    /// Called on a background queue when files change. Set before `watch`.
    var onChange: (@Sendable () -> Void)?

    /// `inspector` asks File Provider where a file is; tests pass made-up answers.
    init(defaults: UserDefaults = .standard, inspector: @escaping @Sendable (String) -> Outcome = { UploadTracker.inspect($0) }) {
        self.defaults = defaults
        self.inspector = inspector
        if let data = defaults.data(forKey: pendingKey),
           let saved = try? JSONDecoder().decode([String: Candidate].self, from: data) {
            candidates = saved
        }
        if let data = defaults.data(forKey: completedKey),
           let saved = try? JSONDecoder().decode([Activity].self, from: data) {
            completed = saved.filter { Self.isSyncable($0.path) }   // drops entries an older build mis-recorded
        }
        if let saved = defaults.dictionary(forKey: gapsKey) as? [String: Date] {
            // A gap outlives a quit: the resume point has already moved past the lost events.
            let due = Date().addingTimeInterval(recheckSettle)
            gaps = saved.mapValues { Gap(since: $0, check: .due(due)) }
        }
        if let saved = defaults.dictionary(forKey: lookedKey) as? [String: [String]] {
            looked = saved.mapValues(Set.init)
        }
    }

    deinit {
        for stream in streams.values { stop(stream) }
    }

    // MARK: Streams

    /// Starts one FSEvents stream per account (covering all its folders) and stops streams for accounts or
    /// folders that are gone. For accounts in `recordingUploadsFor`, uploads seen to finish are remembered
    /// for the Recent list.
    func watch(_ roots: [String: [URL]], recordingUploadsFor: Set<String> = []) {
        dispatchPrecondition(condition: .onQueue(.main))
        for (key, stream) in streams where roots[key] != stream.roots {
            stop(stream)
            streams[key] = nil
        }
        for (key, list) in roots where streams[key] == nil && !list.isEmpty {
            let stream = Stream(key: key, roots: list, tracker: self)
            if start(stream) { streams[key] = stream }
        }
        adopt(streams.mapValues(\.roots), recordingUploadsFor: recordingUploadsFor)
    }

    /// Takes the accounts now watched and their folders (which a re-check walks). Internal (not private) so tests
    /// can watch made-up folders without FSEvents. Gaps of accounts no longer watched are kept: if the account
    /// comes back, its resume point is already past the lost events, so it still needs its re-check.
    ///
    /// An account with a folder no re-check has walked yet gets a gap, Velum's first look: FSEvents only reports
    /// changes, so a file already stuck before Velum watched would never show up. Called on every refresh; an
    /// open gap is left alone, so this never restarts a look under way.
    func adopt(_ roots: [String: [URL]], recordingUploadsFor: Set<String> = []) {
        let keys = Set(roots.keys)
        lock.lock()
        watching = keys
        self.roots = roots
        recordUploads = recordingUploadsFor
        candidates = candidates.filter { keys.contains($0.value.account) }
        let firstLooks = roots.filter { gaps[$0.key] == nil && !isLooked($0.key) }.keys.sorted()
        let now = Date()
        for account in firstLooks { markGap(account, now: now) }
        lock.unlock()
        for account in firstLooks {
            debugLog("tracker", "\(account): no re-check has walked all its folders yet; looking through them before vouching")
        }
    }

    /// Whether a finished re-check has walked every folder the account is watched by. Lock held.
    private func isLooked(_ account: String) -> Bool {
        Set((roots[account] ?? []).map(\.path)).isSubset(of: looked[account] ?? [])
    }

    private func start(_ stream: Stream) -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(stream).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIds in
            guard let info else { return }
            let stream = Unmanaged<Stream>.fromOpaque(info).takeUnretainedValue()
            guard let tracker = stream.tracker,
                  let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as? [String] else { return }
            var events: [(path: String, flags: UInt32)] = []
            var lastID: FSEventStreamEventId = 0
            for i in 0..<count {
                events.append((paths[i], rawFlags[i]))
                lastID = max(lastID, rawIds[i])
            }
            tracker.record(account: stream.key, events: events, lastEventID: lastID)
        }

        // Resume from the saved point so changes made while Velum was quit are caught up, unless that
        // point is more than a day old (replaying that much history is slow): then start now and flag a gap.
        // The start ID is captured before the stream exists, so nothing between the two is skipped.
        let current = FSEventsGetCurrentEventId()
        var since = current
        let saved = (defaults.object(forKey: cursorKey(stream.key)) as? NSNumber)?.uint64Value
        let savedAt = defaults.object(forKey: cursorTimeKey(stream.key)) as? Date
        if let saved, let savedAt, saved <= current, Date().timeIntervalSince(savedAt) < maxReplay {
            since = saved
        } else if saved != nil {
            noteGap(stream.key)
        }

        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let ref = FSEventStreamCreate(nil, callback, &context, stream.roots.map(\.path) as CFArray,
                                            since, 0.5, flags) else { return false }
        FSEventStreamSetDispatchQueue(ref, queue)
        guard FSEventStreamStart(ref) else {
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
            return false
        }
        stream.ref = ref
        if since == current { saveCursor(stream.key, id: current) }
        return true
    }

    private func stop(_ stream: Stream) {
        guard let ref = stream.ref else { return }
        FSEventStreamStop(ref)
        FSEventStreamInvalidate(ref)
        FSEventStreamRelease(ref)
        stream.ref = nil
    }

    private func cursorKey(_ account: String) -> String { "fseventsLastID.\(account)" }
    private func cursorTimeKey(_ account: String) -> String { "fseventsLastTime.\(account)" }

    /// Saves the resume point; it never moves backwards. Pending files are saved first.
    private func saveCursor(_ account: String, id: FSEventStreamEventId) {
        persistIfDirty()
        let saved = (defaults.object(forKey: cursorKey(account)) as? NSNumber)?.uint64Value ?? 0
        defaults.set(NSNumber(value: max(saved, id)), forKey: cursorKey(account))
        defaults.set(Date(), forKey: cursorTimeKey(account))
    }

    private func noteGap(_ account: String) {
        debugLog("tracker", "\(account): saved resume point too old to replay; watching from now and re-checking its folders")
        lock.lock()
        markGap(account, now: Date())
        lock.unlock()
    }

    /// Opens a gap, or extends an open one: its re-check (re)starts a few seconds after the latest loss, and one
    /// already running won't end it. Lock held.
    private func markGap(_ account: String, now: Date) {
        let due = Gap.Check.due(now.addingTimeInterval(recheckSettle))
        guard var gap = gaps[account] else {
            gaps[account] = Gap(since: now, check: due)
            gapsDirty = true
            return
        }
        gap.generation += 1
        if case .running = gap.check {} else { gap.check = due }
        gaps[account] = gap
    }

    // MARK: Events

    /// Internal (not private) so tests can feed made-up events.
    func record(account: String, events: [(path: String, flags: UInt32)], lastEventID: FSEventStreamEventId) {
        let now = Date()
        let lostEvents = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                                | kFSEventStreamEventFlagRootChanged)
        let content = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
                             | kFSEventStreamEventFlagItemRenamed)
        let isFile = UInt32(kFSEventStreamEventFlagItemIsFile)
        let removed = UInt32(kFSEventStreamEventFlagItemRemoved)

        var dropped: UInt32 = 0
        lock.lock()
        for event in events {
            if event.flags & lostEvents != 0 {
                markGap(account, now: now)
                dropped |= event.flags & lostEvents
                continue
            }
            guard event.flags & isFile != 0, Self.isSyncable(event.path) else { continue }
            if event.flags & content != 0 {
                // Created/modified/renamed: (re)check it. Whether it still exists is settled by the check,
                // which also covers create→delete and atomic-save sequences inside one batch. A newer change
                // restarts its clock: "stuck" means the latest version has waited, not that the file is busy.
                var candidate = candidates[event.path]
                    ?? Candidate(account: account, since: now, generation: 0, state: .unchecked, checked: .distantPast)
                candidate.since = now
                candidate.generation += 1
                candidate.state = .unchecked
                candidate.checked = .distantPast
                candidates[event.path] = candidate
                dirty = true
            } else if event.flags & removed != 0, candidates.removeValue(forKey: event.path) != nil {
                dirty = true
            }
        }
        if dropped != 0 {
            debugLog("tracker", "\(account): macOS dropped change events (flags 0x\(String(dropped, radix: 16))); can't vouch until a re-check of its folders finishes")
        }
        if candidates.count > maxCandidates {
            debugLog("tracker", "more than \(maxCandidates) changed files pending; forgetting the oldest and marking a gap")
            let oldest = candidates.sorted { $0.value.since < $1.value.since }.prefix(candidates.count - maxCandidates)
            for (path, candidate) in oldest {
                candidates[path] = nil
                markGap(candidate.account, now: now)
            }
        }
        lock.unlock()

        if lastEventID > 0 { saveCursor(account, id: lastEventID) } else { persistIfDirty() }
        onChange?()
    }

    /// Names OneDrive never uploads. File Provider's own exclusion flag catches the rest.
    static func isSyncable(_ path: String) -> Bool {
        if path.contains("/.Trash/") { return false }
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "Icon\r" || name.hasPrefix("._") || name.hasPrefix("~$") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !["fetch", "tmp"].contains(ext)   // .fetch is OneDrive's own download scratch file
    }

    // MARK: Status

    /// Checks changed files against File Provider (at most `inspectBudget` per call, oldest check first)
    /// and returns what is still pending per account. Reads metadata only, never file contents.
    func summary(now: Date = Date()) -> UploadsSnapshot {
        lock.lock()
        let due = candidates.sorted { $0.value.checked < $1.value.checked }
            .prefix(inspectBudget)
            .map { (path: $0.key, generation: $0.value.generation) }
        lock.unlock()

        let results = due.map { (path: $0.path, generation: $0.generation, state: inspector($0.path)) }

        lock.lock()
        for result in results {
            // Skip if the file changed again while we looked: the newer change gets its own check.
            guard var candidate = candidates[result.path], candidate.generation == result.generation else { continue }
            switch result.state {
            case .pending(let state):
                if candidate.state != state { dirty = true }
                candidate.state = state
                candidate.checked = now
                candidates[result.path] = candidate
            case .uploaded:
                // Only an upload Velum saw pending counts: a file that was already in the cloud when first
                // checked (a download landing, a rename) didn't just upload.
                if recordUploads.contains(candidate.account), candidate.state != .unchecked {
                    completed.removeAll { $0.accountKey == candidate.account && $0.path == result.path }
                    completed.insert(Activity(accountKey: candidate.account, path: result.path,
                                              name: (result.path as NSString).lastPathComponent,
                                              kind: Activity.uploaded, date: now, app: nil), at: 0)
                    if completed.count > completedLimit { completed.removeLast(completed.count - completedLimit) }
                    completedDirty = true
                }
                if candidate.state != .unchecked { uploadedCount[candidate.account, default: 0] += 1 }   // A6, same rule
                candidates[result.path] = nil
                dirty = true
            case .done:
                candidates[result.path] = nil
                dirty = true
            }
        }

        var summaries: [String: UploadSummary] = [:]
        for account in watching { summaries[account] = UploadSummary() }
        for candidate in candidates.values {
            var summary = summaries[candidate.account] ?? UploadSummary()
            switch candidate.state {
            case .uploading:
                summary.uploading += 1
            case .failed(let reason):
                summary.failed.append(reason)
            case .waiting, .unchecked:
                summary.waiting += 1
                summary.oldestWaiting = min(summary.oldestWaiting ?? candidate.since, candidate.since)
            }
            summaries[candidate.account] = summary
        }
        for (account, gap) in gaps where summaries[account] != nil {
            summaries[account]?.coverageGap = true
            summaries[account]?.coverageGapSince = gap.since
            summaries[account]?.coverageFirstLook = !isLooked(account)
            if case .failed(let why, let retry) = gap.check, retry > now {
                summaries[account]?.coverageCheck = .failed(why, retry: retry)
            } else {
                summaries[account]?.coverageCheck = .checking
            }
        }
        // One re-check at a time, the longest-due first.
        var recheck: String?
        if !rechecking, let next = gaps.filter({ watching.contains($0.key) && $0.value.isDue(now) })
            .min(by: { ($0.value.dueDate, $0.key) < ($1.value.dueDate, $1.key) })?.key {
            rechecking = true
            gaps[next]?.check = .running
            recheck = next
        }
        let watched = watching
        let seen = completed.filter { recordUploads.contains($0.accountKey) }

        // Refresh the resume point every few minutes even when nothing changes, using the ID seen one
        // interval ago: everything before it has certainly been delivered by now.
        var advanceTo: FSEventStreamEventId?
        if let checkpoint, now.timeIntervalSince(checkpoint.taken) >= checkpointEvery {
            advanceTo = checkpoint.id
            self.checkpoint = nil
        }
        if checkpoint == nil { checkpoint = (FSEventsGetCurrentEventId(), now) }
        lock.unlock()

        if let advanceTo {
            for account in watched { saveCursor(account, id: advanceTo) }
        } else {
            persistIfDirty()
        }
        if let recheck {
            if rechecksInline { self.recheck(recheck) } else { recheckQueue.async { self.recheck(recheck) } }
        }
        return UploadsSnapshot(watching: watched, accounts: summaries, completed: seen)
    }

    // MARK: Re-checks

    /// Ends a gap by verifying: walks the account's folders and feeds every file File Provider says is waiting,
    /// uploading or failing into the pending files, as if FSEvents had reported it. The gap closes only if the
    /// walk finishes with no newer loss meanwhile; otherwise it stays and says why. Runs off the main thread.
    private func recheck(_ account: String) {
        // Never make a client download anything: with this off, reading an online-only (dataless) folder fails
        // instead of fetching its listing from the server. This thread only, restored afterwards.
        let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if policy >= 0 { setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) } }

        lock.lock()
        let folders = roots[account] ?? []
        let generation = gaps[account]?.generation
        lock.unlock()
        let started = Date()
        debugLog("tracker", "\(account): re-checking \(folders.count) folder\(folders.count == 1 ? "" : "s") for changes a gap may have hidden")
        let walk = walk(account, folders)

        let now = Date()
        var line: String
        lock.lock()
        rechecking = false
        let counts = "looked at \(walk.looked) files in \(Int(now.timeIntervalSince(started))) s, \(walk.found) newly found not in the cloud"
        switch (walk.outcome, gaps[account]) {
        case (_, nil):
            line = "re-check ended (\(counts)); the gap was already gone"
        case (.finished, let gap?) where gap.generation == generation && roots[account] == folders:
            gaps[account] = nil
            looked[account] = Set(folders.map(\.path))
            gapsDirty = true
            line = "re-check finished (\(counts)); the gap is closed"
        case (.failed(let why), var gap?):
            gap.check = .failed(why, retry: now.addingTimeInterval(recheckRetry))
            gaps[account] = gap
            line = "re-check couldn't finish: \(Reasons.recheckFailure(why)) (\(counts)); the gap stays, next try in \(Int(recheckRetry / 60)) min"
        case (_, var gap?):
            // Changes were lost again meanwhile, the folders changed, or the account isn't watched now.
            gap.check = .due(now)
            gaps[account] = gap
            line = "re-check ended (\(counts)), but changes may have been missed again meanwhile; checking again"
        }
        lock.unlock()
        debugLog("tracker", "\(account): \(line)")
        persistIfDirty()
        onChange?()
    }

    private struct Walk {
        enum Outcome: Equatable { case finished, failed(RecheckFailure), cancelled }
        var outcome = Outcome.finished
        var looked = 0      // File Provider lookups
        var found = 0       // files not in the cloud that the tracker didn't hold yet
    }

    /// Walks the folders, skipping online-only folders (nothing local can wait in one), the Trash and names no
    /// service uploads. Asks File Provider about each file in batches of `inspectBudget`, resting as long as
    /// each batch took, so the clients' own daemon stays responsive. Reads metadata only, never file contents.
    private func walk(_ account: String, _ folders: [URL]) -> Walk {
        var walk = Walk()
        guard !folders.isEmpty else {   // not watched now; walking nothing must never close a gap
            walk.outcome = .cancelled
            return walk
        }
        var found: [(path: String, state: State)] = []
        var batchStarted = Date()

        // Adds what this batch found to the pending files; nil means carry on.
        func merge() -> Walk.Outcome? {
            lock.lock()
            defer { lock.unlock() }
            guard watching.contains(account) else { return .cancelled }
            let now = Date()
            for file in found where candidates[file.path] == nil {
                guard candidates.count < maxCandidates else { return .failed(.tooManyPending(maxCandidates)) }
                // The change happened at some point before now; like a replayed FSEvent, it dates from now.
                candidates[file.path] = Candidate(account: account, since: now, generation: 0, state: file.state, checked: now)
                dirty = true
                walk.found += 1
            }
            found.removeAll()
            return nil
        }

        for folder in folders {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
                walk.outcome = .failed(.unreadable)
                return walk
            }
            if Self.isDataless(folder.path) { continue }
            var unreadable = false
            let items = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [],
                errorHandler: { _, error in
                    // Something deleted mid-walk is fine (FSEvents reports deletions); anything else means part
                    // of the folders went unchecked.
                    if Self.isGone(error) { return true }
                    unreadable = true
                    return false
                })
            while let url = items?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values?.isDirectory == true {
                    if url.lastPathComponent == ".Trash" || Self.isDataless(url.path) { items?.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, Self.isSyncable(url.path) else { continue }
                guard walk.looked < recheckLimit else {
                    walk.outcome = merge() ?? .failed(.tooManyFiles(recheckLimit))
                    return walk
                }
                walk.looked += 1
                // Only what File Provider says outright. A file it reports nothing for (OneDrive's hidden root
                // marker, say) is left to FSEvents, as before the gap.
                if case .pending(let state) = inspector(url.path), state != .unchecked {
                    found.append((url.path, state))
                }
                if walk.looked % inspectBudget == 0 {
                    if let stop = merge() {
                        walk.outcome = stop
                        return walk
                    }
                    Thread.sleep(forTimeInterval: min(Date().timeIntervalSince(batchStarted), 5))
                    batchStarted = Date()
                }
            }
            if items == nil || unreadable {
                walk.outcome = merge() ?? .failed(.unreadable)
                return walk
            }
        }
        walk.outcome = merge() ?? .finished
        return walk
    }

    /// An online-only folder or file: its contents aren't on this Mac (`SF_DATALESS`). A plain `lstat`, which
    /// never fetches anything.
    private static func isDataless(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(SF_DATALESS) != 0
    }

    private static func isGone(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) { return true }
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)
    }

    /// Uploads seen to finish per account since launch (seen waiting or uploading, then in the cloud), for
    /// card A6's hourly history. Counts only.
    func uploadedCounts() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return uploadedCount
    }

    /// How long a change may wait before its file counts as stuck: 10 minutes, the same as the stuck alert.
    /// The defaults key `stuckAfterSeconds` overrides it, for tests and live checks.
    static var stuckAfter: TimeInterval {
        let seconds = UserDefaults.standard.double(forKey: "stuckAfterSeconds")
        return seconds > 0 ? seconds : 10 * 60
    }

    /// Files not in the cloud whose latest change is at least `olderThan` old, plus failing files at any
    /// age: failing first (the only ones the user can act on), then oldest first; at most `limit`, with the
    /// full counts. Reads only what the tracker already holds (no File Provider calls), so it's cheap
    /// enough for every refresh. File names go to the panel and the alert only, never to a log.
    func pending(olderThan threshold: TimeInterval, limit: Int = 50, now: Date = Date()) -> PendingList {
        let cutoff = now.addingTimeInterval(-threshold)
        lock.lock()
        let held = candidates
        lock.unlock()

        let files = held.compactMap { path, candidate -> PendingFile? in
            let status: PendingFile.Status
            switch candidate.state {
            case .failed(let text):
                status = .failed(Self.reason(text, path: path))
            case .uploading:
                guard candidate.since <= cutoff else { return nil }
                status = .uploading
            case .waiting, .unchecked:
                guard candidate.since <= cutoff else { return nil }
                status = .waiting
            }
            return PendingFile(account: candidate.account, path: path, since: candidate.since, status: status)
        }
        .sorted { a, b in
            a.isFailing != b.isFailing ? a.isFailing : (a.since, a.path) < (b.since, b.path)
        }
        return PendingList(files: Array(files.prefix(max(0, limit))), total: files.count,
                           perAccount: files.reduce(into: [:]) { $0[$1.account, default: 0] += 1 })
    }

    /// "Report.docx: The file name is too long." → "The file name is too long."
    private static func reason(_ text: String, path: String) -> String {
        let prefix = (path as NSString).lastPathComponent + ": "
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// Where File Provider says a file is. Internal (not private) so tests can give made-up answers.
    enum Outcome {
        case pending(State)
        /// In the cloud now.
        case uploaded
        /// Gone, excluded from sync, or never synced.
        case done
    }

    static func inspect(_ path: String) -> Outcome {
        guard FileManager.default.fileExists(atPath: path) else { return .done }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: keys) else { return .pending(.unchecked) }   // try again later
        if values.isUbiquitousItem == false || values.ubiquitousItemIsExcludedFromSync == true { return .done }
        if values.ubiquitousItemIsUploaded == true { return .uploaded }
        if let error = values.ubiquitousItemUploadingError, !isTransient(error) {
            return .pending(.failed("\(url.lastPathComponent): \(error.localizedDescription)"))
        }
        switch (values.ubiquitousItemIsUploaded, values.ubiquitousItemIsUploading) {
        case (_, true?): return .pending(.uploading)
        case (false?, _): return .pending(.waiting)
        default: return .pending(.unchecked)     // provider hasn't reported yet
        }
    }

    /// iCloud marks every new or edited file with "couldn't access your iCloud account"
    /// (NSUbiquitousFileUbiquityServerNotAvailable, 4355) until its upload finishes, about 20 s for a small
    /// file here. Read as "waiting": if the server really is unreachable, the file stays waiting and the
    /// stuck alert fires after 10 minutes.
    static func isTransient(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == NSUbiquitousFileUbiquityServerNotAvailable
    }

    private func persistIfDirty() {
        lock.lock()
        let pendingData = dirty ? try? JSONEncoder().encode(candidates) : nil
        let completedData = completedDirty ? try? JSONEncoder().encode(completed) : nil
        let openGaps = gapsDirty ? gaps.mapValues(\.since) : nil
        let lookedFolders = gapsDirty ? looked.mapValues { $0.sorted() } : nil
        let wrotePending = dirty, wroteCompleted = completedDirty
        dirty = false
        completedDirty = false
        gapsDirty = false
        lock.unlock()
        if wrotePending { defaults.set(pendingData, forKey: pendingKey) }
        if wroteCompleted { defaults.set(completedData, forKey: completedKey) }
        if let openGaps { defaults.set(openGaps, forKey: gapsKey) }
        if let lookedFolders { defaults.set(lookedFolders, forKey: lookedKey) }
    }
}
