import AppKit
import Foundation
import Testing
@testable import Velum

/// Card A5. A stand-in for everything the sleep guard reads: a fake clock, NSWorkspace's notifications posted on
/// a private center, made-up files under /Users/test, a lock screen that's up or not, and macOS's upload flag.
/// Nothing touches NSWorkspace, File Provider or Velum's real defaults.
@MainActor
private final class Rig {
    final class Clock { var now = Fixture.now }

    let clock: Clock
    let center = NotificationCenter()
    let defaults: UserDefaults
    let sleepGuard: SleepGuard
    /// With a notifier, notes and the cover go through it, and `refresh()` runs both as the app does.
    let notifier: Notifier?

    var snapshot = Snapshot()
    var pending = PendingList()
    var alertsOn = true
    var locked = false
    var inCloud: Set<String> = []
    var gone: Set<String> = []
    var lookups = 0
    struct Note { let title: String; let body: String; let logged: String; let problem: Bool }
    var posted: [Note] = []
    var shown: [Note] = []      // what the notifier showed (its banner fallback)
    var cover = SleepGuardCover()

    init(defaults: UserDefaults? = nil, notifier: Notifier? = nil) {
        let clock = Clock()
        let suite = defaults ?? UserDefaults(suiteName: "velum-sleep-\(UUID().uuidString)")!
        self.clock = clock
        self.defaults = suite
        // A fixed 10-minute cap: another suite briefly changes the shared `stuckAfterSeconds`.
        sleepGuard = SleepGuard(defaults: suite, clock: { clock.now }, stuckAfter: { 10 * 60 })
        self.notifier = notifier
    }

    func connect() {
        notifier?.fallback = { [unowned self] title, body, problem in
            self.shown.append(Note(title: title, body: body, logged: "", problem: problem))
        }
        sleepGuard.connect(SleepGuard.Sources(
            snapshot: { [unowned self] in self.snapshot },
            pending: { [unowned self] in self.pending },
            alertsOn: { [unowned self] in self.alertsOn },
            post: { [unowned self] words, problem in
                self.posted.append(Note(title: words.title, body: words.body, logged: words.logged, problem: problem))
                self.notifier?.note(SleepGuard.alertKey, title: words.title, body: words.body, isProblem: problem,
                                    logged: words.logged)
            },
            cover: { [unowned self] cover in
                self.cover = cover
                self.notifier?.sleepGuard = cover
            },
            screenLocked: { [unowned self] in self.locked },
            whereIs: { [unowned self] path in
                self.lookups += 1
                return self.inCloud.contains(path) ? .inCloud : self.gone.contains(path) ? .gone : .unknown
            }), center: center, queue: nil)
    }

    func sleep() { center.post(name: NSWorkspace.willSleepNotification, object: nil) }
    func wake() { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
    func powerOff() { center.post(name: NSWorkspace.willPowerOffNotification, object: nil) }
    func advance(_ seconds: TimeInterval) { clock.now += seconds }

    /// One refresh, `seconds` later: the guard checks first, then the notifier sees the same snapshot.
    func tick(after seconds: TimeInterval = 0) {
        advance(seconds)
        sleepGuard.tick()
        notifier?.update(snapshot, enabled: alertsOn, now: clock.now)
    }

    var titles: [String] { posted.map(\.title) }
}

private let minute: TimeInterval = 60
private let oneDriveFolder = "/Users/test/Library/CloudStorage/OneDrive-Personal"
private let iCloudFolder = "/Users/test/Library/Mobile Documents/com~apple~CloudDocs"
private let googleRoot = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-alex.sample@example.com")

private func path(_ name: String) -> String { "\(oneDriveFolder)/Documents/\(name)" }

private func file(_ name: String, account: String = "Personal", age: TimeInterval = minute,
                  _ status: PendingFile.Status = .waiting, folder: String = oneDriveFolder) -> PendingFile {
    PendingFile(account: account, path: "\(folder)/Documents/\(name)", since: Fixture.now.addingTimeInterval(-age), status: status)
}

private func list(_ files: [PendingFile]) -> PendingList {
    PendingList(files: files, total: files.count, perAccount: files.reduce(into: [:]) { $0[$1.account, default: 0] += 1 })
}

private func oneDrive(running: Bool = true, waiting: Int = 0, since: Date? = nil) -> Snapshot {
    var s = Snapshot()
    s.providers = [ProviderStatus(id: .oneDrive, clientRunning: running)]
    var uploads = UploadSummary()
    uploads.waiting = waiting
    uploads.oldestWaiting = since
    s.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), running: running), uploads: uploads)]
    return s
}

/// A Google Drive account whose own queue holds `queued` changes; nil: a queue Velum can't read (card A7).
private func google(queued: Int?) -> AccountStatus {
    var e = Fixture.evidence(GoogleDriveProvider.config(email: "alex.sample@example.com", root: googleRoot),
                             report: queued.map { GoogleDriveProvider.report(queued: $0, now: Fixture.now) })
    if let queued, queued > 0 { e.workingSince = Fixture.now.addingTimeInterval(-minute) }
    return Fixture.status(e)
}

private func googleSnapshot(queued: Int?) -> Snapshot {
    var s = Snapshot()
    s.providers = [ProviderStatus(id: .googleDrive, clientRunning: true)]
    s.accounts = [google(queued: queued)]
    return s
}

// MARK: Each moment, each outcome

@MainActor
@Suite struct SleepGuardMoments {
    @Test func everythingSafeAtSleepSaysNothing() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.sleep()
        #expect(rig.sleepGuard.watch == nil)
        #expect(rig.cover == SleepGuardCover())
        rig.advance(8 * 3600)
        rig.wake()
        rig.tick(after: 5)
        rig.tick(after: 15 * minute)
        #expect(rig.posted.isEmpty)
    }

    @Test func uploadedSinceSleepWaitsForTheUnlock() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 3)
        rig.pending = list([file("a.txt"), file("b.txt"), file("c.txt")])
        rig.sleep()
        #expect(rig.sleepGuard.watch?.files.count == 3)
        #expect(rig.lookups == 0)                                // sleep returns at once: no File Provider calls
        #expect(rig.cover.files.count == 3)                      // A2's stuck alert for them waits from now
        #expect(rig.defaults.data(forKey: SleepGuard.defaultsKey) != nil)

        rig.advance(8 * 3600)
        rig.locked = true                                        // the lock screen is up at wake
        rig.wake()
        rig.tick(after: 5)
        rig.pending = list([])
        rig.inCloud = Set(["a.txt", "b.txt", "c.txt"].map(path))
        rig.tick(after: 20)
        #expect(rig.posted.isEmpty)                              // the banner couldn't be seen yet
        rig.locked = false
        rig.tick(after: 30)
        #expect(rig.titles == ["Uploaded after sleep"])
        #expect(rig.posted.first?.body == "3 files weren’t in the cloud when your Mac slept. They’re there now.")
        #expect(rig.posted.first?.problem == false)
        #expect(rig.sleepGuard.watch == nil)
        #expect(rig.defaults.data(forKey: SleepGuard.defaultsKey) == nil)
        rig.tick(after: 10 * minute)
        #expect(rig.posted.count == 1)                           // one note per wake
    }

    @Test func stillPendingAfterTwoQuietMinutesThenOneFollowUp() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 2)
        rig.pending = list([file("Report.docx", age: 2 * minute), file("b.txt")])
        rig.sleep()
        rig.advance(8 * 3600)
        rig.wake()
        rig.tick(after: 1)                                       // unlocked: the two minutes start here
        rig.tick(after: 118)
        #expect(rig.posted.isEmpty)
        rig.tick(after: 2)
        #expect(rig.titles == ["Still not in the cloud"])
        #expect(rig.posted.first?.body == "Report.docx and 1 more haven’t uploaded since your Mac woke.")
        #expect(rig.posted.first?.logged == "2 files haven’t uploaded since your Mac woke.")   // no file name in the log
        #expect(rig.posted.first?.problem == true)

        rig.tick(after: 5 * minute)
        rig.tick(after: 30 * minute)
        #expect(rig.posted.count == 1)                           // not repeated
        #expect(rig.cover.accounts == ["Personal"])              // A2's stuck alert for them still waits

        rig.pending = list([])
        rig.inCloud = [path("Report.docx"), path("b.txt")]
        rig.tick(after: 5)
        #expect(rig.titles == ["Still not in the cloud", "Uploads: resolved"])
        #expect(rig.posted.last?.body == "The files from before your Mac slept are in the cloud now.")
        #expect(rig.sleepGuard.watch == nil)
    }

    @Test func oneFileIsSingular() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 1)
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 2 * minute)
        #expect(rig.posted.last?.body == "a.txt hasn’t uploaded since your Mac woke.")
        rig.pending = list([])
        rig.inCloud = [path("a.txt")]
        rig.tick(after: 5)
        #expect(rig.posted.last?.body == "The file from before your Mac slept is in the cloud now.")
    }

    @Test func anUploadInProgressWaitsUpToTheStuckThreshold() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("big.mov", .uploading)])
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 3 * minute)
        rig.tick(after: 6 * minute)
        #expect(rig.posted.isEmpty)                              // moving: not a problem yet
        rig.tick(after: minute)                                  // 10 minutes after unlock
        #expect(rig.posted.map(\.body) == ["big.mov hasn’t uploaded since your Mac woke."])
    }

    @Test func progressRestartsTheTwoMinutes() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("a.txt", age: 3 * minute), file("b.txt", age: 2 * minute), file("c.txt")])
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.pending = list([file("b.txt", age: 2 * minute), file("c.txt")])
        rig.inCloud = [path("a.txt")]
        rig.tick(after: 100)                                     // one went up
        rig.tick(after: 30)
        #expect(rig.posted.isEmpty)                              // 130 s after unlock, but only 30 s since progress
        rig.tick(after: 91)
        #expect(rig.posted.map(\.body) == ["b.txt and 1 more haven’t uploaded since your Mac woke."])
    }

    @Test func aLockedScreenHoldsTheProblemAndTheWaitStartsAtUnlock() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.locked = true
        rig.wake()
        rig.tick(after: 30 * minute)
        #expect(rig.posted.isEmpty)
        rig.locked = false
        rig.tick(after: 5)
        rig.tick(after: 119)
        #expect(rig.posted.isEmpty)
        rig.tick(after: 1)
        #expect(rig.titles == ["Still not in the cloud"])
    }

    @Test func shutdownAlertsAtOnceAndTheNextLaunchSaysItMadeIt() {
        let first = Rig()
        first.connect()
        first.snapshot = oneDrive(waiting: 2)
        first.pending = list([file("a.txt"), file("b.txt")])
        first.powerOff()
        #expect(first.titles == ["Not in the cloud yet"])
        #expect(first.posted.first?.body == "2 files aren’t in the cloud yet. They’ll upload the next time OneDrive runs.")
        #expect(first.posted.first?.problem == true)
        #expect(first.lookups == 0)

        let next = Rig(defaults: first.defaults)                 // the next launch
        next.snapshot = oneDrive()
        next.inCloud = [path("a.txt"), path("b.txt")]
        next.connect()
        next.tick(after: 3)
        #expect(next.titles == ["Uploaded since shutdown"])
        #expect(next.posted.first?.body == "2 files weren’t in the cloud when you last shut down or logged out. They’re there now.")
    }

    @Test func theNextLaunchSaysWhenTheyStillHavent() {
        let first = Rig()
        first.connect()
        first.snapshot = oneDrive(waiting: 2)
        first.pending = list([file("a.txt", age: 5 * minute), file("b.txt")])
        first.powerOff()

        let next = Rig(defaults: first.defaults)
        next.snapshot = Snapshot()                               // the first refresh hasn't come in yet
        next.pending = first.pending                             // the tracker's saved list
        next.connect()
        next.tick(after: 3)
        next.tick(after: 5 * minute)
        #expect(next.posted.isEmpty)                             // nothing judged without accounts to judge by
        next.snapshot = oneDrive(waiting: 2)
        next.tick(after: 3)
        next.tick(after: 2 * minute)
        #expect(next.posted.map(\.body) == ["a.txt and 1 more haven’t uploaded since you last shut down or logged out."])
    }

    @Test func aMacThatRanFlatAsleepGetsItsCheckAtLaunch() {
        let first = Rig()
        first.connect()
        first.snapshot = oneDrive(waiting: 1)
        first.pending = list([file("a.txt")])
        first.sleep()                                            // and never woke

        let next = Rig(defaults: first.defaults)
        next.snapshot = oneDrive(waiting: 1)
        next.pending = first.pending
        next.connect()
        next.tick(after: 3)
        next.tick(after: 2 * minute)
        #expect(next.posted.map(\.body) == ["a.txt hasn’t uploaded since your Mac slept."])
        next.pending = list([])
        next.inCloud = [path("a.txt")]
        next.tick(after: 5)
        #expect(next.posted.last?.body == "The file from before your Mac slept is in the cloud now.")
    }

    @Test func aCancelledLogOutLeavesNothingForTheNextLaunch() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 1)
        rig.pending = list([file("a.txt")])
        rig.powerOff()
        rig.tick(after: minute)
        #expect(rig.sleepGuard.watch != nil)
        rig.tick(after: minute + 1)                              // still running two minutes on
        #expect(rig.sleepGuard.watch == nil)
        #expect(rig.defaults.data(forKey: SleepGuard.defaultsKey) == nil)
        #expect(rig.posted.count == 1)
    }

    @Test func alertsOffSaysNothingButStillKeepsTrack() {
        let rig = Rig()
        rig.connect()
        rig.alertsOn = false
        rig.snapshot = oneDrive(waiting: 1)
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 2 * minute)                              // the problem, unseen
        rig.alertsOn = true                                      // switching on doesn't replay it (A2's rule)
        rig.tick(after: 5 * minute)
        #expect(rig.posted.isEmpty)
        rig.pending = list([])
        rig.inCloud = [path("a.txt")]
        rig.tick(after: 5)
        #expect(rig.titles == ["Uploads: resolved"])             // its follow-up, now that alerts are on

        rig.alertsOn = false
        rig.pending = list([file("b.txt")])
        rig.powerOff()
        #expect(rig.posted.count == 1)
        #expect(rig.defaults.data(forKey: SleepGuard.defaultsKey) != nil)   // the next launch still checks
    }
}

// MARK: What isn't this note's business

@MainActor
@Suite struct SleepGuardHandsOver {
    @Test func filesAlreadyFailingAtSleepAreA2s() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("bad.txt", .failed("The file name is too long."))])
        rig.sleep()
        #expect(rig.sleepGuard.watch == nil)                     // they'd come back at every wake otherwise
    }

    @Test func aFileThatStartsFailingGoesToA2() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.pending = list([file("a.txt", .failed("Access denied."))])
        rig.tick(after: 5)
        #expect(rig.posted.isEmpty)
        #expect(rig.sleepGuard.watch == nil)
        #expect(rig.cover == SleepGuardCover())
    }

    @Test func deletedOrMovedFilesDidNotUpload() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("a.txt"), file("b.txt")])
        rig.sleep()
        rig.wake()
        rig.pending = list([])
        rig.inCloud = [path("a.txt")]
        rig.gone = [path("b.txt")]
        rig.tick(after: 5)
        #expect(rig.posted.map(\.body) == ["1 file wasn’t in the cloud when your Mac slept. It’s there now."])

        let gone = Rig()
        gone.connect()
        gone.snapshot = oneDrive()
        gone.pending = list([file("a.txt")])
        gone.sleep()
        gone.wake()
        gone.pending = list([])
        gone.gone = [path("a.txt")]
        gone.tick(after: 5)
        #expect(gone.posted.isEmpty)
        #expect(gone.sleepGuard.watch == nil)
    }

    @Test func offTheListWithoutTheUploadFlagIsNotUploaded() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive()
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.pending = list([])                                   // left the list; macOS doesn't say "uploaded"
        rig.tick(after: 1)
        rig.tick(after: 3 * minute)
        #expect(rig.posted.isEmpty)
        #expect(rig.sleepGuard.watch != nil)                     // waits for the flag
        rig.tick(after: 7 * minute)
        #expect(rig.posted.isEmpty)                              // then gives up quietly
        #expect(rig.sleepGuard.watch == nil)
    }

    @Test func aStoppedAppIsA2sButARestartCounts() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 1)
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.snapshot = oneDrive(running: false)
        rig.tick(after: 1)
        rig.tick(after: 2 * minute)
        #expect(rig.posted.isEmpty)                              // A2 says "OneDrive stopped"
        #expect(rig.sleepGuard.watch == nil)

        let restarted = Rig()
        restarted.connect()
        restarted.snapshot = oneDrive(waiting: 1)
        restarted.pending = list([file("a.txt")])
        restarted.sleep()
        restarted.wake()
        restarted.snapshot = oneDrive(running: false)
        restarted.tick(after: 1)
        restarted.snapshot = oneDrive()
        restarted.pending = list([])
        restarted.inCloud = [path("a.txt")]
        restarted.tick(after: minute)
        #expect(restarted.titles == ["Uploaded after sleep"])
    }

    @Test func aSecondSleepMergesAndDoesNotRepeatTheProblem() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = oneDrive(waiting: 1)
        rig.pending = list([file("a.txt")])
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 2 * minute)
        #expect(rig.titles == ["Still not in the cloud"])

        rig.sleep()                                              // a.txt still waiting
        #expect(rig.sleepGuard.watch?.reported == [path("a.txt")])
        rig.advance(3600)
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 5 * minute)
        #expect(rig.posted.count == 1)                           // the same file isn't reported twice

        rig.pending = list([])
        rig.inCloud = [path("a.txt")]
        rig.tick(after: 5)
        #expect(rig.titles == ["Still not in the cloud", "Uploads: resolved"])
    }
}

// MARK: Google Drive's queue (no file count)

@MainActor
@Suite struct SleepGuardQueues {
    @Test func aQueueThatCaughtUp() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = googleSnapshot(queued: 2)
        rig.sleep()
        #expect(rig.sleepGuard.watch?.queues.count == 1)
        rig.wake()
        rig.snapshot = googleSnapshot(queued: 0)                 // Google Drive's own live "Up to date"
        rig.tick(after: 5)
        #expect(rig.titles == ["Google Drive caught up"])
        #expect(rig.posted.first?.body == "Google Drive was still syncing changes when your Mac slept. It has caught up.")
    }

    @Test func aQueueStillBusyAtTenMinutes() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = googleSnapshot(queued: 2)
        rig.sleep()
        rig.wake()
        rig.tick(after: 1)
        rig.tick(after: 5 * minute)
        #expect(rig.posted.isEmpty)                              // its own queue at work counts as moving
        rig.tick(after: 5 * minute)
        #expect(rig.titles == ["Google Drive is still syncing"])
        #expect(rig.posted.first?.body == "It hasn’t finished the changes it had queued when your Mac slept.")
        rig.snapshot = googleSnapshot(queued: 0)
        rig.tick(after: 5)
        #expect(rig.titles.last == "Google Drive: resolved")
        #expect(rig.posted.last?.body == "It has finished the changes it had queued when your Mac slept.")
    }

    @Test func anUnreadableQueueIsNotCaughtUp() {
        let rig = Rig()
        rig.connect()
        rig.snapshot = googleSnapshot(queued: 2)
        rig.sleep()
        rig.wake()
        rig.snapshot = googleSnapshot(queued: nil)               // card A7: no queue to read, no status
        rig.tick(after: 1)
        rig.tick(after: 11 * minute)
        #expect(rig.posted.isEmpty)
    }
}

// MARK: Wording

@Suite struct SleepGuardWords {
    func watch(_ files: [(String, String)], services: [String: ProviderID], queues: Set<String> = []) -> SleepGuard.Watch {
        var w = SleepGuard.Watch(moment: .powerOff, at: Fixture.now)
        w.files = Dictionary(uniqueKeysWithValues: files)
        w.services = services
        w.queues = queues
        return w
    }

    @Test func shutdownNamesTheAppsThatWillUploadThem() {
        let one = SleepGuard.powerOffWords(watch([("/Users/test/a", "Personal")], services: ["Personal": .oneDrive]))
        #expect(one.body == "1 file isn’t in the cloud yet. It’ll upload the next time OneDrive runs.")
        let two = SleepGuard.powerOffWords(watch([("/Users/test/a", "Personal"), ("/Users/test/b", "g"), ("/Users/test/c", "g")],
                                                 services: ["Personal": .oneDrive, "g": .googleDrive]))
        #expect(two.body == "3 files aren’t in the cloud yet. They’ll upload the next time OneDrive and Google Drive run.")
        let iCloud = SleepGuard.powerOffWords(watch([("/Users/test/a", "iCloudDrive"), ("/Users/test/b", "Personal")],
                                                    services: ["iCloudDrive": .iCloud, "Personal": .oneDrive]))
        #expect(iCloud.body == "2 files aren’t in the cloud yet. They’ll upload after you log in again.")
        #expect(iCloud.title == "Not in the cloud yet")
    }

    @Test func shutdownWithOnlyAQueue() {
        let words = SleepGuard.powerOffWords(watch([], services: ["g": .googleDrive], queues: ["g"]))
        #expect(words.title == "Google Drive hasn’t finished")
        #expect(words.body == "Some changes aren’t in the cloud yet. Google Drive will carry on the next time it runs.")
    }

    @Test func countedFilesLeadWhenAQueueIsAlsoPending() {
        let words = SleepGuard.powerOffWords(watch([("/Users/test/a", "Personal")], services: ["Personal": .oneDrive, "g": .googleDrive],
                                                   queues: ["g"]))
        #expect(words.body == "1 file isn’t in the cloud yet. It’ll upload the next time OneDrive and Google Drive run.")
    }

    @Test func theLogGetsCountsNotNames() {
        let w = SleepGuard.outstanding(.sleep, at: Fixture.now, snapshot: Snapshot(),
                                       pending: list([file("x.pages", account: ICloudProvider.key, folder: iCloudFolder)]))
        #expect(w.files.count == 1)
        #expect(SleepGuard.describe(w) == "1 file on the way up (another service 1)")   // no file name in the log
    }
}

// MARK: With A2's notifier

@MainActor
@Suite struct SleepGuardAndA2 {
    func stuckSnapshot(_ names: [String], since: Date) -> Snapshot {
        var s = oneDrive(waiting: names.count, since: since)
        s.stuck = list(names.map { file($0, age: Fixture.now.timeIntervalSince(since)) })
        return s
    }

    /// Stuck and notified before sleep, uploaded 20 s after wake: one note, the guard's, not A2's "resolved" too.
    @Test func oneNoteAfterWakeNotTwo() {
        let rig = Rig(notifier: Notifier())
        rig.connect()
        let since = Fixture.now.addingTimeInterval(-11 * minute)
        rig.snapshot = stuckSnapshot(["a.txt", "b.txt"], since: since)
        rig.pending = rig.snapshot.stuck
        rig.tick()
        rig.tick(after: 31)
        #expect(rig.shown.map(\.title) == ["Personal: uploads are stuck"])

        rig.sleep()
        rig.advance(8 * 3600)
        rig.wake()
        rig.tick(after: 5)
        rig.snapshot = oneDrive()
        rig.pending = list([])
        rig.inCloud = [path("a.txt"), path("b.txt")]
        rig.tick(after: 15)
        rig.tick(after: 3)
        rig.tick(after: 60)
        #expect(rig.shown.map(\.title) == ["Personal: uploads are stuck", "Uploaded after sleep"])
    }

    /// Still waiting after wake: the guard's note, and A2's stuck alert for the same files stays quiet.
    @Test func a2WaitsWhileTheGuardCoversTheSameFiles() {
        let rig = Rig(notifier: Notifier())
        rig.connect()
        let since = Fixture.now.addingTimeInterval(-2 * minute)
        rig.snapshot = stuckSnapshot([], since: since)
        rig.snapshot.accounts = oneDrive(waiting: 1, since: since).accounts
        rig.pending = list([file("a.txt", age: 2 * minute)])
        rig.sleep()
        rig.advance(8 * 3600)
        rig.wake()
        // Waiting since before the night: past A2's 10 minutes at once.
        rig.snapshot = stuckSnapshot(["a.txt"], since: since)
        rig.tick(after: 1)
        rig.tick(after: 40)
        rig.tick(after: 90)
        #expect(rig.shown.map(\.title) == ["Still not in the cloud"])
        rig.tick(after: 30 * minute)
        #expect(rig.shown.count == 1)
    }

    /// A different file stuck in the same account still gets A2's alert.
    @Test func aNewStuckFileStillAlerts() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        notifier.sleepGuard = SleepGuardCover(files: [path("a.txt")], accounts: ["Personal"])
        let since = Fixture.now.addingTimeInterval(-11 * minute)
        var s = oneDrive(waiting: 2, since: since)
        s.stuck = list([file("a.txt", age: 11 * minute)])
        notifier.update(s, enabled: true, now: Fixture.now)
        notifier.update(s, enabled: true, now: Fixture.now.addingTimeInterval(31))
        #expect(shown.isEmpty)                                   // only the guard's file: it waits
        s.stuck = list([file("a.txt", age: 11 * minute), file("new.txt", age: 11 * minute)])
        notifier.update(s, enabled: true, now: Fixture.now.addingTimeInterval(40))
        #expect(shown == ["Personal: uploads are stuck"])
    }

    @Test func withoutTheGuardA2IsUnchanged() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        let since = Fixture.now.addingTimeInterval(-11 * minute)
        var s = oneDrive(waiting: 1, since: since)
        s.stuck = list([file("a.txt", age: 11 * minute)])
        notifier.update(s, enabled: true, now: Fixture.now)
        notifier.update(s, enabled: true, now: Fixture.now.addingTimeInterval(31))
        notifier.update(oneDrive(), enabled: true, now: Fixture.now.addingTimeInterval(60))
        #expect(shown == ["Personal: uploads are stuck", "Personal: resolved"])
    }
}
