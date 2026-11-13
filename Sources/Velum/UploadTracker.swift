import CoreServices
import Foundation

/// Uploads in flight for one account: local changes macOS hasn't finished sending to OneDrive.
struct UploadSummary: Equatable {
    var uploading = 0
    var waiting = 0
    var failed: [String] = []      // "<file name>: <reason>"
    var oldestWaiting: Date?
    /// FSEvents may have missed changes (dropped events, a resume point too old to replay, too many files),
    /// so "nothing pending" isn't proof right now.
    var coverageGap = false
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
/// Pending files and the FSEvents resume point are saved, so a quit or restart doesn't lose track.
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

    private let queue = DispatchQueue(label: "Velum.fsevents", qos: .utility)
    private let lock = NSLock()
    // Guarded by lock:
    private var candidates: [String: Candidate] = [:]
    private var watching: Set<String> = []
    private var gapUntil: [String: Date] = [:]
    private var dirty = false
    private var completedDirty = false
    private var checkpoint: (id: FSEventStreamEventId, taken: Date)?
    private var recordUploads: Set<String> = []
    private var completed: [Activity] = []
    // Main thread only:
    private var streams: [String: Stream] = [:]

    private let defaults: UserDefaults
    private let pendingKey = "pendingUploads"
    private let completedKey = "recentUploads"
    private let completedLimit = 30
    private let maxCandidates = 5000
    private let inspectBudget = 400                 // File Provider lookups per refresh
    private let maxReplay: TimeInterval = 86_400    // don't replay more than a day of change history
    private let gapDuration: TimeInterval = 15 * 60
    private let checkpointEvery: TimeInterval = 10 * 60

    private static let keys: Set<URLResourceKey> = [
        .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey, .ubiquitousItemIsExcludedFromSyncKey,
    ]

    /// Called on a background queue when files change. Set before `watch`.
    var onChange: (@Sendable () -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: pendingKey),
           let saved = try? JSONDecoder().decode([String: Candidate].self, from: data) {
            candidates = saved
        }
        if let data = defaults.data(forKey: completedKey),
           let saved = try? JSONDecoder().decode([Activity].self, from: data) {
            completed = saved.filter { Self.isSyncable($0.path) }   // drops entries an older build mis-recorded
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
        let keys = Set(streams.keys)
        lock.lock()
        watching = keys
        recordUploads = recordingUploadsFor
        candidates = candidates.filter { keys.contains($0.value.account) }
        lock.unlock()
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
        debugLog("tracker", "\(account): saved resume point too old to replay; watching from now, so changes made meanwhile may be missed")
        lock.lock()
        gapUntil[account] = Date().addingTimeInterval(gapDuration)
        lock.unlock()
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
                gapUntil[account] = now.addingTimeInterval(gapDuration)
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
            debugLog("tracker", "\(account): macOS dropped change events (flags 0x\(String(dropped, radix: 16))); can't vouch for 15 minutes")
        }
        if candidates.count > maxCandidates {
            debugLog("tracker", "more than \(maxCandidates) changed files pending; forgetting the oldest and marking a gap")
            let oldest = candidates.sorted { $0.value.since < $1.value.since }.prefix(candidates.count - maxCandidates)
            for (path, candidate) in oldest {
                candidates[path] = nil
                gapUntil[candidate.account] = now.addingTimeInterval(gapDuration)
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

        let results = due.map { (path: $0.path, generation: $0.generation, state: Self.inspect($0.path)) }

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
        for (account, until) in gapUntil where until > now { summaries[account]?.coverageGap = true }
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
        return UploadsSnapshot(watching: watched, accounts: summaries, completed: seen)
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

    private enum Outcome {
        case pending(State)
        /// In the cloud now.
        case uploaded
        /// Gone, excluded from sync, or never synced.
        case done
    }

    private static func inspect(_ path: String) -> Outcome {
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
        let wrotePending = dirty, wroteCompleted = completedDirty
        dirty = false
        completedDirty = false
        lock.unlock()
        if wrotePending { defaults.set(pendingData, forKey: pendingKey) }
        if wroteCompleted { defaults.set(completedData, forKey: completedKey) }
    }
}
