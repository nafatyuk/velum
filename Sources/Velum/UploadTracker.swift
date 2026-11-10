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

/// Watches each OneDrive folder for changed files (FSEvents) and asks File Provider where each one is
/// (`ubiquitousItemIsUploaded`, `…IsUploading`, `…UploadingError`). OneDrive keeps those flags honest:
/// a changed file reads "not uploaded" at once, "uploading" when OneDrive starts, and "uploaded" within a
/// second or two of OneDrive's own record. Public APIs, no permission needed, and unlike OneDrive's icon
/// text it keeps working after OneDrive restarts with its icons hidden.
///
/// Pending files and the FSEvents resume point are saved, so a quit or restart doesn't lose track.
final class UploadTracker: @unchecked Sendable {
    private final class Stream {
        let key: String
        let folder: URL
        var ref: FSEventStreamRef?
        weak var tracker: UploadTracker?

        init(key: String, folder: URL, tracker: UploadTracker) {
            self.key = key
            self.folder = folder
            self.tracker = tracker
        }
    }

    private enum State: Codable, Equatable {
        case unchecked, waiting, uploading
        case failed(String)
    }

    private struct Candidate: Codable {
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
    private var checkpoint: (id: FSEventStreamEventId, taken: Date)?
    // Main thread only:
    private var streams: [String: Stream] = [:]

    private let defaults = UserDefaults.standard
    private let pendingKey = "pendingUploads"
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

    init() {
        if let data = defaults.data(forKey: pendingKey),
           let saved = try? JSONDecoder().decode([String: Candidate].self, from: data) {
            candidates = saved
        }
    }

    deinit {
        for stream in streams.values { stop(stream) }
    }

    // MARK: Streams

    /// Starts one FSEvents stream per account folder and stops streams for folders that are gone.
    func watch(_ folders: [String: URL]) {
        dispatchPrecondition(condition: .onQueue(.main))
        for (key, stream) in streams where folders[key] != stream.folder {
            stop(stream)
            streams[key] = nil
        }
        for (key, folder) in folders where streams[key] == nil {
            let stream = Stream(key: key, folder: folder, tracker: self)
            if start(stream) { streams[key] = stream }
        }
        let keys = Set(streams.keys)
        lock.lock()
        watching = keys
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
        guard let ref = FSEventStreamCreate(nil, callback, &context, [stream.folder.path] as CFArray,
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
        lock.lock()
        gapUntil[account] = Date().addingTimeInterval(gapDuration)
        lock.unlock()
    }

    // MARK: Events

    private func record(account: String, events: [(path: String, flags: UInt32)], lastEventID: FSEventStreamEventId) {
        let now = Date()
        let lostEvents = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
                                | kFSEventStreamEventFlagRootChanged)
        let content = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemModified
                             | kFSEventStreamEventFlagItemRenamed)
        let isFile = UInt32(kFSEventStreamEventFlagItemIsFile)
        let removed = UInt32(kFSEventStreamEventFlagItemRemoved)

        lock.lock()
        for event in events {
            if event.flags & lostEvents != 0 {
                gapUntil[account] = now.addingTimeInterval(gapDuration)
                continue
            }
            guard event.flags & isFile != 0, Self.isSyncable(event.path) else { continue }
            if event.flags & content != 0 {
                // Created/modified/renamed: (re)check it. Whether it still exists is settled by the check,
                // which also covers create→delete and atomic-save sequences inside one batch.
                var candidate = candidates[event.path]
                    ?? Candidate(account: account, since: now, generation: 0, state: .unchecked, checked: .distantPast)
                candidate.generation += 1
                candidate.state = .unchecked
                candidate.checked = .distantPast
                candidates[event.path] = candidate
                dirty = true
            } else if event.flags & removed != 0, candidates.removeValue(forKey: event.path) != nil {
                dirty = true
            }
        }
        if candidates.count > maxCandidates {
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
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" || name == "Icon\r" || name.hasPrefix("._") || name.hasPrefix("~$") { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return !["fetch", "tmp"].contains(ext)   // .fetch is OneDrive's own download scratch file
    }

    // MARK: Status

    /// Checks changed files against File Provider (at most `inspectBudget` per call, oldest check first)
    /// and returns what is still pending per account. Reads metadata only, never file contents.
    func summary(now: Date = Date()) -> (watching: Set<String>, accounts: [String: UploadSummary]) {
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
            if let state = result.state {
                if candidate.state != state { dirty = true }
                candidate.state = state
                candidate.checked = now
                candidates[result.path] = candidate
            } else {
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
        return (watched, summaries)
    }

    /// nil = done with this file (uploaded, gone, or never synced).
    private static func inspect(_ path: String) -> State? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: keys) else { return .unchecked }   // try again later
        if values.isUbiquitousItem == false || values.ubiquitousItemIsExcludedFromSync == true { return nil }
        if let error = values.ubiquitousItemUploadingError {
            return .failed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        switch (values.ubiquitousItemIsUploaded, values.ubiquitousItemIsUploading) {
        case (true?, _): return nil
        case (_, true?): return .uploading
        case (false?, _): return .waiting
        default: return .unchecked     // provider hasn't reported yet
        }
    }

    private func persistIfDirty() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let data = try? JSONEncoder().encode(candidates)
        lock.unlock()
        defaults.set(data, forKey: pendingKey)
    }
}
