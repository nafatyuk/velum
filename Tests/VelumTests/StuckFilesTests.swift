import CoreServices
import Foundation
import Testing
@testable import Velum

/// A stand-in `UploadTracker`: made-up pending files seeded through its own saved state, in a throwaway
/// defaults suite, so nothing touches FSEvents, File Provider or Velum's real defaults.
private struct StandIn {
    static let folder = "/Users/test/Library/CloudStorage/OneDrive-Personal"
    let defaults: UserDefaults
    let tracker: UploadTracker

    init(_ files: [(name: String, account: String, age: TimeInterval, state: UploadTracker.State)], now: Date = Fixture.now) {
        defaults = UserDefaults(suiteName: "velum-tests-\(UUID().uuidString)")!
        let seeded = Dictionary(uniqueKeysWithValues: files.map { file in
            (Self.path(file.name), UploadTracker.Candidate(account: file.account, since: now.addingTimeInterval(-file.age),
                                                           generation: 1, state: file.state, checked: now))
        })
        defaults.set(try! JSONEncoder().encode(seeded), forKey: "pendingUploads")
        tracker = UploadTracker(defaults: defaults)
    }

    static func path(_ name: String) -> String { "\(folder)/Documents/\(name)" }
}

private let minute: TimeInterval = 60
private let threshold: TimeInterval = 10 * minute

@Suite struct StuckListing {
    @Test func thresholdKeepsOutRecentChangesButNotFailures() {
        let t = StandIn([
            ("fresh.txt", "Personal", 9 * minute, .waiting),
            ("old.txt", "Personal", 11 * minute, .waiting),
            ("unconfirmed.txt", "Personal", 12 * minute, .unchecked),
            ("bad.txt", "Personal", 1 * minute, .failed("bad.txt: The file name is too long.")),
        ]).tracker
        let list = t.pending(olderThan: threshold, now: Fixture.now)
        #expect(Set(list.files.map(\.name)) == ["old.txt", "unconfirmed.txt", "bad.txt"])
        #expect(list.total == 3)
        // At exactly the threshold a file counts as stuck.
        let edge = StandIn([("edge.txt", "Personal", threshold, .waiting)]).tracker
        #expect(edge.pending(olderThan: threshold, now: Fixture.now).files.map(\.name) == ["edge.txt"])
    }

    @Test func failingFirstThenOldestFirst() {
        let t = StandIn([
            ("b.txt", "Personal", 20 * minute, .waiting),
            ("a.txt", "Business1", 3 * 60 * minute, .uploading),
            ("c.txt", "Personal", 15 * minute, .waiting),
            ("late-failure.txt", "Personal", 2 * minute, .failed("late-failure.txt: Access denied.")),
            ("old-failure.txt", "Business1", 30 * minute, .failed("old-failure.txt: Access denied.")),
        ]).tracker
        let names = t.pending(olderThan: threshold, now: Fixture.now).files.map(\.name)
        #expect(names == ["old-failure.txt", "late-failure.txt", "a.txt", "b.txt", "c.txt"])
    }

    @Test func capKeepsTheTotal() {
        let files = (1...60).map { i in (name: "file\(i).txt", account: "Personal", age: TimeInterval(i) * minute + threshold,
                                         state: UploadTracker.State.waiting) }
        let list = StandIn(files).tracker.pending(olderThan: threshold, now: Fixture.now)
        #expect(list.files.count == 50)
        #expect(list.total == 60)
        #expect(list.files.first?.name == "file60.txt")   // the oldest
        #expect(StandIn(files).tracker.pending(olderThan: threshold, limit: 5, now: Fixture.now).files.count == 5)
    }

    @Test func failureReasonsLoseTheFileName() {
        let t = StandIn([
            ("Report.docx", "Personal", minute, .failed("Report.docx: The file name is too long.")),
            ("x.txt", "Personal", minute, .failed("Something else went wrong")),
        ]).tracker
        let reasons = Dictionary(uniqueKeysWithValues: t.pending(olderThan: threshold, now: Fixture.now).files.map { ($0.name, $0.status) })
        #expect(reasons["Report.docx"] == .failed("The file name is too long."))
        #expect(reasons["x.txt"] == .failed("Something else went wrong"))
    }

    @Test func statesAndFields() {
        let t = StandIn([
            ("up.mov", "Business1", 40 * minute, .uploading),
            ("wait.txt", "Personal", 50 * minute, .unchecked),
        ]).tracker
        let files = t.pending(olderThan: threshold, now: Fixture.now).files
        #expect(files.map(\.status) == [.waiting, .uploading])
        #expect(files[0].account == "Personal")
        #expect(files[0].path == StandIn.path("wait.txt"))
        #expect(files[0].since == Fixture.now.addingTimeInterval(-50 * minute))
    }

    /// A file edited again while listed: its newer change restarts its clock, so it leaves the list until
    /// that change has waited too.
    @Test func newerChangeRestartsTheClock() {
        let now = Date()
        let t = StandIn([("draft.txt", "Personal", 20 * minute, .waiting)], now: now).tracker
        #expect(t.pending(olderThan: threshold, now: now).files.map(\.name) == ["draft.txt"])
        let flags = UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        t.record(account: "Personal", events: [(StandIn.path("draft.txt"), flags)], lastEventID: 0)
        #expect(t.pending(olderThan: threshold, now: Date()).files.isEmpty)
        #expect(t.pending(olderThan: threshold, now: Date().addingTimeInterval(threshold + 1)).files.map(\.name) == ["draft.txt"])
    }

    /// A file that's gone (deleted, or never really there) leaves the list at the next check.
    @Test func goneFilesLeave() {
        let t = StandIn([("deleted.txt", "Personal", 20 * minute, .waiting)]).tracker
        _ = t.summary(now: Fixture.now)
        #expect(t.pending(olderThan: threshold, now: Fixture.now).total == 0)
    }

    @Test func thresholdOverride() {
        UserDefaults.standard.removeObject(forKey: "stuckAfterSeconds")
        #expect(UploadTracker.stuckAfter == 600)
        UserDefaults.standard.set(30, forKey: "stuckAfterSeconds")
        #expect(UploadTracker.stuckAfter == 30)
        UserDefaults.standard.removeObject(forKey: "stuckAfterSeconds")
    }
}

private func file(_ name: String, account: String = "Personal", age: TimeInterval, _ status: PendingFile.Status,
                  now: Date = Fixture.now) -> PendingFile {
    PendingFile(account: account, path: StandIn.path(name), since: now.addingTimeInterval(-age), status: status)
}

private func list(_ files: [PendingFile], total: Int? = nil) -> PendingList {
    PendingList(files: files, total: total ?? files.count,
                perAccount: files.reduce(into: [:]) { $0[$1.account, default: 0] += 1 })
}

@Suite struct StuckSection {
    @Test func fiveRowsThenShowMore() {
        let files = (1...7).map { file("f\($0).txt", age: TimeInterval($0) * 3600, .waiting) }
        let collapsed = StuckWording.layout(list(files), expanded: false)
        #expect(collapsed.rows.count == 5)
        #expect(collapsed.hidden == 2)
        #expect(collapsed.unlisted == 0)
        let open = StuckWording.layout(list(files), expanded: true)
        #expect(open.rows.count == 7)
        #expect(open.hidden == 0)
        let few = StuckWording.layout(list(Array(files.prefix(3))), expanded: true)
        #expect(few.rows.count == 3 && few.hidden == 0 && few.unlisted == 0)
    }

    @Test func pastTheCapTheRestIsCountedOnceExpanded() {
        let files = (1...50).map { file("f\($0).txt", age: TimeInterval($0) * 3600, .waiting) }
        let collapsed = StuckWording.layout(list(files, total: 127), expanded: false)
        #expect(collapsed.hidden == 45)
        #expect(collapsed.unlisted == 0)
        let open = StuckWording.layout(list(files, total: 127), expanded: true)
        #expect(open.rows.count == 50)
        #expect(open.unlisted == 77)
    }

    @Test func waitedAges() {
        let now = Fixture.now
        #expect(StuckWording.waited(now.addingTimeInterval(-12 * minute), now: now) == "12 min")
        #expect(StuckWording.waited(now.addingTimeInterval(-2 * 3600 - 59 * minute), now: now) == "2 hr")
        #expect(StuckWording.waited(now.addingTimeInterval(-1 * 86_400), now: now) == "1 day")
        #expect(StuckWording.waited(now.addingTimeInterval(-3 * 86_400), now: now) == "3 days")
        #expect(StuckWording.waited(now.addingTimeInterval(-30), now: now) == "under 1 min")
        #expect(StuckWording.waited(now.addingTimeInterval(-9 * 86_400), now: now).hasPrefix("since "))
    }

    @Test func subtitles() {
        let now = Fixture.now
        #expect(StuckWording.subtitle(file("a.txt", age: 12 * minute, .waiting), account: nil, now: now) == "Waiting 12 min")
        #expect(StuckWording.subtitle(file("a.txt", age: 2 * 3600, .waiting), account: "Personal", now: now)
                == "Waiting 2 hr · Personal")
        #expect(StuckWording.subtitle(file("a.mov", age: 25 * minute, .uploading), account: nil, now: now)
                == "Uploading · changed 25 min ago")
        #expect(StuckWording.subtitle(file("a.txt", age: minute, .failed("Too long.")), account: "Personal", now: now)
                == "Can’t upload · Personal")
        // A stopped app is named as the cause (macOS then reports "couldn't connect to the server").
        #expect(StuckWording.subtitle(file("a.txt", age: minute, .failed("No server.")), account: nil, stopped: "OneDrive",
                                      now: now) == "Can’t upload · OneDrive isn’t running")
        #expect(StuckWording.subtitle(file("a.txt", age: 12 * minute, .waiting), account: nil, stopped: "OneDrive", now: now)
                == "Waiting 12 min")
    }

    @Test func voiceOverSaysWhatTheRowHides() {
        let now = Fixture.now
        let waiting = StuckWording.spoken(file("Report.docx", age: 2 * 3600, .waiting), account: "OneDrive, Personal",
                                          folder: "In Documents/Taxes", now: now)
        #expect(waiting == "Report.docx, waiting 2 hours, OneDrive, Personal, In Documents/Taxes")
        let failing = StuckWording.spoken(file("Report.docx", age: minute, .failed("The file name is too long.")),
                                          account: "Personal", folder: nil, now: now)
        #expect(failing == "Report.docx, can’t upload. The file name is too long, Personal")
        let stopped = StuckWording.spoken(file("a.txt", age: minute, .failed("No server.")), account: "Personal",
                                          folder: nil, stopped: "OneDrive", now: now)
        #expect(stopped == "a.txt, can’t upload, OneDrive isn’t running. No server, Personal")
    }

    @Test func helpNamesTheFolder() {
        let f = file("a.txt", age: 12 * minute, .waiting)
        let help = StuckWording.help(f, folder: "In Documents", now: Fixture.now)
        #expect(help.hasPrefix("In Documents · changed "))
        #expect(help.hasSuffix("(click to show in Finder)"))
    }
}

/// The stuck alert names the oldest waiting file; its debug-log twin never does.
@MainActor @Suite struct StuckAlert {
    func account(pending: Int, oldest: TimeInterval) -> AccountStatus {
        var uploads = UploadSummary()
        uploads.waiting = pending
        uploads.oldestWaiting = Fixture.now.addingTimeInterval(-oldest)
        return Fixture.status(Fixture.evidence(Fixture.oneDrive()), uploads: uploads)
    }

    @Test func namesTheOldestWaitingFile() {
        let stuck = list([file("Report.docx", age: 30 * minute, .waiting), file("b.txt", age: 20 * minute, .waiting),
                          file("c.mov", age: 15 * minute, .uploading)])
        let body = Notifier.stuckBody(account(pending: 5, oldest: 30 * minute), stuck: stuck, now: Fixture.now)
        let clock = RelTime.clock(Fixture.now.addingTimeInterval(-30 * minute))
        // Counts the three files past the threshold, not the five pending.
        #expect(body.shown == "Report.docx and 2 more, waiting since \(clock).")
        #expect(body.logged == "3 files waiting since \(clock)")
        #expect(!body.logged.contains("Report"))
    }

    @Test func oneFile() {
        let stuck = list([file("Report.docx", age: 30 * minute, .waiting)])
        let body = Notifier.stuckBody(account(pending: 1, oldest: 30 * minute), stuck: stuck, now: Fixture.now)
        #expect(body.shown == "Report.docx has been waiting since \(RelTime.clock(Fixture.now.addingTimeInterval(-30 * minute))).")
    }

    @Test func otherAccountsFilesAreNotNamed() {
        let stuck = list([file("theirs.txt", account: "Business1", age: 60 * minute, .waiting)])
        let body = Notifier.stuckBody(account(pending: 2, oldest: 30 * minute), stuck: stuck, now: Fixture.now)
        #expect(body.shown == body.logged + ".")
        #expect(body.shown.hasPrefix("2 files waiting since "))
    }

    @Test func earlierDaysGetADate() {
        let now = Fixture.now
        #expect(Notifier.moment(now.addingTimeInterval(-60), now: now) == RelTime.clock(now.addingTimeInterval(-60)))
        #expect(Notifier.moment(now.addingTimeInterval(-3 * 86_400), now: now).count > RelTime.clock(now).count)
    }

    @Test func longNamesLoseTheirMiddle() {
        let name = "Quarterly-Budget-Forecast-for-the-whole-department-final-v3.xlsx"
        let short = Notifier.shortName(name)
        #expect(short.count == 40)
        #expect(short.hasPrefix("Quarterly-Budget-For"))
        #expect(short.hasSuffix("final-v3.xlsx"))
        #expect(short.contains("…"))
        #expect(Notifier.shortName("Report.docx") == "Report.docx")
    }
}
