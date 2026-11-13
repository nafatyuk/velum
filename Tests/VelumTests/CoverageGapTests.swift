import CoreServices
import Foundation
import Testing
@testable import Velum

/// A made-up account folder in the temporary directory, a throwaway defaults suite, and made-up File Provider
/// answers keyed by file name, so nothing touches FSEvents, File Provider, real cloud folders or Velum's real
/// defaults. Re-checks run inline, on the test's own thread.
private final class Sandbox: @unchecked Sendable {
    static let account = "Personal"
    let folder: URL
    let suite = "velum-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let asked = Asked()

    init() {
        let made = FileManager.default.temporaryDirectory.appending(path: "velum-gap-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // The real path (/private/var/…), the form FSEvents reports, so both ways of finding a file agree.
        folder = URL(fileURLWithPath: made.path.withCString { realpath($0, nil).map { String(cString: $0) } } ?? made.path)
        defaults = UserDefaults(suiteName: suite)!
    }

    deinit {
        // Undo any chmod first, or the folder can't be removed.
        if let items = FileManager.default.enumerator(atPath: folder.path) {
            for case let item as String in items { chmod(folder.appending(path: item).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: folder)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func file(_ relative: String) -> URL {
        let url = folder.appending(path: relative)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: url)
        return url
    }

    /// A tracker watching the sandbox folder. Files without an answer read as uploaded.
    func tracker(_ answers: [String: UploadTracker.Outcome] = [:], fallback: UploadTracker.Outcome = .uploaded,
                 during: (@Sendable (String) -> Void)? = nil) -> UploadTracker {
        // Holds the sandbox, so its folder lasts as long as the tracker walking it.
        let tracker = UploadTracker(defaults: defaults) { [self] path in
            let name = (path as NSString).lastPathComponent
            asked.add(name)
            during?(name)
            return answers[name] ?? fallback
        }
        tracker.rechecksInline = true
        tracker.adopt([Self.account: [folder]])
        return tracker
    }
}

/// The names the made-up File Provider was asked about.
private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ name: String) { lock.lock(); list.append(name); lock.unlock() }
    var names: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(list) }
}

private let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs)

private extension UploadTracker {
    /// macOS dropping events for the account, as FSEvents reports it.
    func loseEvents(in folder: URL) {
        record(account: Sandbox.account, events: [(folder.path, lost)], lastEventID: 0)
    }

    func account(at offset: TimeInterval) -> UploadSummary? {
        summary(now: Date().addingTimeInterval(offset)).accounts[Sandbox.account]
    }
}

@Suite struct CoverageGapRecheck {
    @Test func aGapEndsOnlyWhenTheRecheckFinishesAndFeedsWhatItFound() {
        let box = Sandbox()
        box.file("waiting.txt")
        box.file("Sub/Deeper/uploading.mov")
        box.file("failing.docx")
        box.file("in-the-cloud.txt")
        box.file(".849C9593-D756-4E56-8D6E-42412F2A707B")   // OneDrive's root marker: no flags at all
        let tracker = box.tracker([
            "waiting.txt": .pending(.waiting),
            "uploading.mov": .pending(.uploading),
            "failing.docx": .pending(.failed("failing.docx: Access denied.")),
            ".849C9593-D756-4E56-8D6E-42412F2A707B": .pending(.unchecked),
        ])
        let before = Date()
        tracker.loseEvents(in: box.folder)

        // Straight away: a gap, being re-checked, dated from the loss. The re-check waits for the burst to settle.
        let first = tracker.account(at: 0)
        #expect(first?.coverageGap == true)
        #expect(first?.coverageCheck == .checking)
        #expect((first?.coverageGapSince).map { $0 >= before && $0 <= Date() } == true)
        #expect(box.asked.names.isEmpty)

        // Once due, the re-check runs (inline here). The summary it was started from still shows the gap.
        #expect(tracker.account(at: 10)?.coverageGap == true)
        #expect(box.asked.names.contains("in-the-cloud.txt"))

        // Then the gap is closed, and what File Provider said isn't in the cloud is pending, as if FSEvents had seen it.
        let after = tracker.account(at: 11)
        #expect(after?.coverageGap == false)
        #expect(after?.coverageGapSince == nil)
        #expect(after?.coverageCheck == nil)
        #expect(after?.waiting == 1)
        #expect(after?.uploading == 1)
        #expect(after?.failed == ["failing.docx: Access denied."])
        // A file File Provider says nothing about isn't counted as waiting.
        let names = Set(tracker.pending(olderThan: 0).files.map(\.name))
        #expect(names == ["waiting.txt", "uploading.mov", "failing.docx"])
    }

    @Test func nothingFoundMeansCoveredAgain() {
        let box = Sandbox()
        box.file("a.txt")
        box.file("Folder/b.txt")
        let tracker = box.tracker()
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        let after = tracker.account(at: 11)
        #expect(after == UploadSummary())
        #expect(box.asked.names == ["a.txt", "b.txt"])
        // The row vouches again: a healthy report gains "Nothing pending".
        let status = Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date")), uploads: after)
        #expect(status.uploadsCovered)
    }

    @Test func skipsTheTrashAndNamesNoServiceUploads() {
        let box = Sandbox()
        box.file("real.txt")
        for name in [".DS_Store", "~$Report.docx", "._real.txt", "draft.tmp", "big.fetch", ".Trash/old.txt"] { box.file(name) }
        let tracker = box.tracker(fallback: .pending(.waiting))
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        #expect(tracker.account(at: 11)?.waiting == 1)
        #expect(box.asked.names == ["real.txt"])   // the rest were never even looked up
    }

    @Test func excludedAndVanishedFilesAreLeftOut() {
        let box = Sandbox()
        box.file("excluded.nosync")
        box.file("gone.txt")
        box.file("kept.txt")
        let tracker = box.tracker(["excluded.nosync": .done, "gone.txt": .done, "kept.txt": .pending(.waiting)])
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        #expect(tracker.pending(olderThan: 0).files.map(\.name) == ["kept.txt"])
    }

    @Test func fileTrackedBeforeTheGapKeepsItsClock() throws {
        let box = Sandbox()
        let tracked = box.file("tracked.txt").path
        let tracker = box.tracker(["tracked.txt": .pending(.waiting)])
        let changed = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        tracker.record(account: Sandbox.account, events: [(tracked, changed)], lastEventID: 0)
        let since = try #require(tracker.pending(olderThan: 0).files.first?.since)
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        let files = tracker.pending(olderThan: 0).files
        #expect(files.count == 1)
        #expect(files.first?.since == since)
    }
}

@Suite struct CoverageGapStays {
    /// Under the old timer every one of these gaps had ended 15 minutes after the loss, re-checked or not.
    @Test func anUnreadableFolderKeepsTheGapAndSaysSo() throws {
        let box = Sandbox()
        box.file("Locked/inside.txt")
        chmod(box.folder.appending(path: "Locked").path, 0)
        let tracker = box.tracker(fallback: .pending(.waiting))
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)

        let after = try #require(tracker.account(at: 11))
        #expect(after.coverageGap)
        guard case .failed(.unreadable, let retry) = after.coverageCheck else {
            Issue.record("expected an unreadable failure, got \(String(describing: after.coverageCheck))")
            return
        }
        #expect(retry > Date().addingTimeInterval(29 * 60))
        let status = Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date")), uploads: after)
        #expect(!status.uploadsCovered)
        #expect(status.reason == Reasons.coverageGap(since: after.coverageGapSince, check: after.coverageCheck))

        // Long past the old 15 minutes, and past the retry, which fails again: still a gap.
        #expect(tracker.account(at: 3 * 3600)?.coverageGap == true)
        #expect(tracker.account(at: 3 * 3600 + 1)?.coverageGap == true)
    }

    @Test func aMissingFolderKeepsTheGap() {
        let box = Sandbox()
        let tracker = box.tracker()
        tracker.adopt([Sandbox.account: [box.folder.appending(path: "Not There")]])
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        #expect(tracker.account(at: 11)?.coverageCheck.map { if case .failed(.unreadable, _) = $0 { true } else { false } } == true)
    }

    @Test func tooManyFilesToLookAtKeepsTheGap() {
        let box = Sandbox()
        for i in 1...3 { box.file("file\(i).txt") }
        let tracker = box.tracker(fallback: .pending(.waiting))
        tracker.recheckLimit = 2
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        let after = tracker.account(at: 11)
        #expect(after?.coverageGap == true)
        #expect(after?.coverageCheck.map { if case .failed(.tooManyFiles(2), _) = $0 { true } else { false } } == true)
        // What it did find still counts.
        #expect(after?.waiting == 2)
    }

    @Test func tooManyPendingKeepsTheGap() {
        let box = Sandbox()
        for i in 1...3 { box.file("file\(i).txt") }
        let tracker = box.tracker(fallback: .pending(.waiting))
        tracker.maxCandidates = 2
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)
        let after = tracker.account(at: 11)
        #expect(after?.coverageCheck.map { if case .failed(.tooManyPending(2), _) = $0 { true } else { false } } == true)
        #expect(after?.waiting == 2)
    }

    @Test func aLossDuringTheRecheckNeedsAnother() {
        let box = Sandbox()
        box.file("a.txt")
        let holder = Holder()
        let tracker = box.tracker(during: { _ in
            // macOS drops events again while the first re-check is walking.
            if let t = holder.takeOnce() { t.loseEvents(in: box.folder) }
        })
        holder.tracker = tracker
        tracker.loseEvents(in: box.folder)
        _ = tracker.account(at: 10)                       // first re-check, spoiled
        #expect(tracker.account(at: 11)?.coverageGap == true)   // …which also starts the second one
        #expect(tracker.account(at: 12)?.coverageGap == false)
    }

    @Test func aGapOutlivesARestart() {
        let box = Sandbox()
        box.file("a.txt")
        let first = box.tracker()
        first.loseEvents(in: box.folder)
        let since = first.account(at: 0)?.coverageGapSince

        // Quit before the re-check ran: the next launch still has the gap, dated the same.
        let second = box.tracker()
        let reopened = second.account(at: 0)
        #expect(reopened?.coverageGap == true)
        #expect(reopened?.coverageGapSince == since)
        _ = second.account(at: 10)
        #expect(second.account(at: 11)?.coverageGap == false)

        // Closed for good once a re-check finished.
        #expect(box.tracker().account(at: 0)?.coverageGap == false)
    }

    @Test func tooManyChangedFilesOpensAGapThatARecheckCloses() {
        let box = Sandbox()
        let paths = (1...3).map { box.file("file\($0).txt").path }
        let tracker = box.tracker()   // all three turn out to be in the cloud
        tracker.maxCandidates = 2
        let changed = UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
        tracker.record(account: Sandbox.account, events: paths.map { ($0, changed) }, lastEventID: 0)
        #expect(tracker.account(at: 0)?.coverageGap == true)
        _ = tracker.account(at: 10)
        #expect(tracker.account(at: 11)?.coverageGap == false)
    }
}

/// Lets the made-up File Provider reach the tracker it belongs to, once.
private final class Holder: @unchecked Sendable {
    weak var tracker: UploadTracker?
    private var used = false
    func takeOnce() -> UploadTracker? {
        defer { used = true }
        return used ? nil : tracker
    }
}
