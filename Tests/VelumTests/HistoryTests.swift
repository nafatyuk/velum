import Foundation
import Testing
@testable import Velum

// Card A6: sync history per account. Made-up accounts and file names only; every History here writes to a
// throwaway folder, never to ~/Library/Application Support/Velum.

private let minute: TimeInterval = 60
private let hour: TimeInterval = 3600
private let stuckAfter: TimeInterval = 10 * minute
/// Fixture.now (2027-01-15 08:00 UTC, a Friday) is exactly on an hour: hour 500000.
private let h0 = 500_000

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US")
    return c
}

/// A throwaway history file and helpers to feed it refreshes.
@MainActor
private struct Recorder {
    let dir = FileManager.default.temporaryDirectory.appending(path: "velum-history-\(UUID().uuidString)")
    var file: URL { dir.appending(path: "history.json") }
    let history: History

    init() {
        history = History(file: dir.appending(path: "history.json"), now: Fixture.now)
    }

    /// One refresh every `step` seconds from `from` through `to`, as Store.refresh would call it.
    func drive(_ snapshot: Snapshot, from: Date, to: Date, step: TimeInterval = 30,
               uploaded: (Date) -> [String: Int] = { _ in [:] }) {
        var t = from
        while t <= to {
            history.record(snapshot, uploaded: uploaded(t), now: t, stuckAfter: stuckAfter)
            t += step
        }
    }

    func text() throws -> String {
        history.save(now: Fixture.now, wait: true)
        return try String(contentsOf: file, encoding: .utf8)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }
}

private func account(_ uploads: UploadSummary = UploadSummary(), config: AccountConfig = Fixture.oneDrive()) -> AccountStatus {
    Fixture.status(Fixture.evidence(config, report: Fixture.report(.ok, "Up to date")), uploads: uploads)
}

private func snapshot(_ accounts: [AccountStatus], stuck: [String: Int] = [:], activity: [Activity] = []) -> Snapshot {
    var s = Snapshot()
    s.accounts = accounts
    s.stuck = PendingList(files: [], total: stuck.values.reduce(0, +), perAccount: stuck)
    s.activity = activity
    return s
}

/// A watched hour, for building lines directly.
private func watched(_ hour: Int, uploads: Int = 0, stuckFor: Int = 0, failing: Int = 0, gap: Int = 0,
                     seconds: Int = 3600) -> HistoryHour {
    var h = HistoryHour(hour: hour)
    h.watched = seconds
    h.uploads = uploads
    h.stuckFor = stuckFor
    h.stuck = stuckFor > 0 ? 1 : 0
    h.failing = failing
    h.gap = gap
    return h
}

private func at(_ hour: Int, _ offset: TimeInterval = 0) -> Date {
    HistoryHour.start(of: hour).addingTimeInterval(offset)
}

// MARK: - Bucketing

@MainActor @Suite struct HistoryBucketing {
    @Test func hoursAreUTCHourNumbers() {
        #expect(HistoryHour.hour(of: Fixture.now) == h0)
        #expect(HistoryHour.hour(of: Fixture.now.addingTimeInterval(3599.9)) == h0)
        #expect(HistoryHour.hour(of: Fixture.now.addingTimeInterval(-0.1)) == h0 - 1)
        #expect(HistoryHour.start(of: h0) == Fixture.now)
    }

    @Test func stepsSplitAtTheHourAndAddUpExactly() {
        let parts = History.split(from: at(h0, -30), to: at(h0, 15))
        #expect(parts.map(\.hour) == [h0 - 1, h0])
        #expect(parts.map(\.seconds) == [30, 15])
        // Many 2.5 s refreshes add up to the whole span, with no rounding drift.
        var total = 0
        var t = at(h0, 0.3)
        while t < at(h0, 1799) {
            total += History.split(from: t, to: t.addingTimeInterval(2.5)).reduce(0) { $0 + $1.seconds }
            t += 2.5
        }
        #expect(total == 1800)
    }

    @Test func eachRefreshLandsInItsOwnHour() {
        let r = Recorder()
        defer { r.cleanUp() }
        let waiting = snapshot([account(UploadSummary(waiting: 2))])
        // 08:50 to 09:10; one upload finishes at 08:55 and another at 09:05.
        r.drive(waiting, from: at(h0, 50 * minute), to: at(h0, 70 * minute)) { t in
            ["Personal": (t >= at(h0, 55 * minute) ? 1 : 0) + (t >= at(h0, 65 * minute) ? 1 : 0)]
        }
        let hours = r.history.hours(for: "Personal")
        #expect(hours.map(\.hour) == [h0, h0 + 1])
        #expect(hours.map(\.watched) == [600, 600])
        #expect(hours.map(\.uploads) == [1, 1])
        #expect(hours.map(\.waiting) == [2, 2])
    }

    @Test func everyAccountOfEveryServiceIsRecorded() {
        let r = Recorder()
        defer { r.cleanUp() }
        let google = GoogleDriveProvider.config(email: "sam@example.com",
                                                root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-sam@example.com"))
        let all = snapshot([account(), account(config: Fixture.oneDrive("Business1", name: "Northwind Traders")),
                            account(config: Fixture.iCloud()), account(config: google)])
        r.drive(all, from: at(h0), to: at(h0, 5 * minute))
        for key in ["Personal", "Business1", ICloudProvider.key, google.key] {
            #expect(r.history.hours(for: key).first?.watched == 300, "\(key)")
        }
    }

    @Test func aStuckQueueCountsAsStuckWork() {
        var queue = account()
        queue.workPending = true
        queue.workingSince = Fixture.now.addingTimeInterval(-15 * minute)
        #expect(History.stuckWork(queue, list: PendingList(), now: Fixture.now, after: stuckAfter) == 1)
        queue.workingSince = Fixture.now.addingTimeInterval(-5 * minute)
        #expect(History.stuckWork(queue, list: PendingList(), now: Fixture.now, after: stuckAfter) == 0)
        // Failing files are A3's too, but they're counted as failing, not as waiting.
        let failing = account(UploadSummary(failed: ["x: no"]))
        let list = PendingList(files: [], total: 3, perAccount: ["Personal": 3])
        #expect(History.stuckWork(failing, list: list, now: Fixture.now, after: stuckAfter) == 2)
    }
}

// MARK: - Retention and restarts

@MainActor @Suite struct HistoryRetention {
    @Test func keepsThirtyDays() {
        let r = Recorder()
        defer { r.cleanUp() }
        let one = snapshot([account()])
        let monthAgo = Fixture.now.addingTimeInterval(-30 * 86_400)
        r.history.record(one, uploaded: [:], now: monthAgo, stuckAfter: stuckAfter)                 // hour h0 - 720
        r.history.record(one, uploaded: [:], now: monthAgo.addingTimeInterval(hour), stuckAfter: stuckAfter)   // h0 - 719
        r.history.record(one, uploaded: [:], now: Fixture.now, stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal").map(\.hour) == [h0 - 719, h0])
        #expect(History.keepHours == 720)
    }

    @Test func survivesARestartAndPrunesOnLoad() throws {
        let r = Recorder()
        defer { r.cleanUp() }
        let one = snapshot([account(UploadSummary(waiting: 1))])
        r.history.record(one, uploaded: [:], now: Fixture.now.addingTimeInterval(-719 * hour), stuckAfter: stuckAfter)
        r.drive(one, from: Fixture.now, to: Fixture.now.addingTimeInterval(20 * minute)) { t in
            ["Personal": t >= Fixture.now.addingTimeInterval(10 * minute) ? 3 : 0]
        }
        r.history.save(wait: true)
        let before = r.history.hours(for: "Personal")

        let restarted = History(file: r.file, now: Fixture.now.addingTimeInterval(30 * minute))
        #expect(restarted.hours(for: "Personal") == before)
        #expect(restarted.hours(for: "Personal").last?.uploads == 3)
        // A day later the oldest hour is past 30 days and goes at load.
        let later = History(file: r.file, now: Fixture.now.addingTimeInterval(hour))
        #expect(later.hours(for: "Personal").map(\.hour) == [h0])
    }

    @Test func anUnreadableFileStartsAfresh() throws {
        let r = Recorder()
        defer { r.cleanUp() }
        try FileManager.default.createDirectory(at: r.dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: r.file)
        #expect(History(file: r.file, now: Fixture.now).records.isEmpty)
    }
}

// MARK: - Quiet versus stalled

@MainActor @Suite struct QuietAndStalled {
    /// One whole watched hour with this evidence; returns the hour's record.
    func hourWith(_ uploads: UploadSummary, stuck: Int = 0, uploadedAt: TimeInterval? = nil) -> HistoryHour? {
        let r = Recorder()
        defer { r.cleanUp() }
        let s = snapshot([account(uploads)], stuck: stuck > 0 ? ["Personal": stuck] : [:])
        r.drive(s, from: at(h0), to: at(h0, hour - 1), step: 60) { t in
            ["Personal": uploadedAt.map { t >= at(h0, $0) ? 1 : 0 } ?? 0]
        }
        return r.history.hours(for: "Personal").first
    }

    @Test func nothingWaitingIsQuiet() {
        #expect(hourWith(UploadSummary())?.kind() == .quiet)
    }

    @Test func aShortWaitIsStillQuiet() {
        // Files waiting under the stuck threshold, nothing uploaded: not a stall (the consult's ruling).
        let h = hourWith(UploadSummary(waiting: 2))
        #expect(h?.waiting == 2)
        #expect(h?.kind() == .quiet)
    }

    @Test func workWaitingAndNothingUploadedIsStalled() {
        let h = hourWith(UploadSummary(waiting: 3), stuck: 3)
        #expect(h?.stuck == 3)
        #expect(h?.stuckFor == 3540)
        #expect(h?.kind() == .stalled)
    }

    @Test func anUploadThatHourMeansNotStalled() {
        let h = hourWith(UploadSummary(waiting: 3), stuck: 1, uploadedAt: 30 * minute)
        #expect(h?.uploads == 1)
        #expect(h?.kind() == .active)
    }

    @Test func aBriefStuckMomentIsNotAStall() {
        var h = watched(h0, stuckFor: 4 * 60)
        #expect(h.kind() == .quiet)
        h.stuckFor = 5 * 60
        #expect(h.kind() == .stalled)
    }

    @Test func failingComesFirst() {
        let h = hourWith(UploadSummary(waiting: 1, failed: ["Report.docx: The file name is too long."]), stuck: 2)
        #expect(h?.failing == 1)
        #expect(h?.stuck == 1)
        #expect(h?.kind() == .failing)
    }

    @Test func stalledNowAcrossWatchedHours() {
        let now = at(h0, 30 * minute)
        var hours = (h0 - 200 ..< h0 - 30).map { watched($0, uploads: 1) }
        hours += (h0 - 30 ..< h0).map { watched($0, stuckFor: 3600) }
        hours.append(watched(h0, stuckFor: 1800, seconds: 1800))
        let live = HistoryLatest(stuck: 2, failing: 0, at: now)
        let line = HistoryLine.make(hours: hours, latest: live, now: now, calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "Uploads seen on 6 of the last 7 days; stalled since yesterday.")
        #expect(line.stallNote == "Stalled for 1 day, since yesterday")
        // Without live evidence nothing is said about now.
        let old = HistoryLine.make(hours: hours, latest: nil, now: now, calendar: utc, stuckAfter: stuckAfter)
        #expect(old.summary == "Uploads seen on 6 of the last 7 days.")
        #expect(old.stallNote == nil)
    }

    @Test func aStallAcrossHoursVelumDidntSeeIsOnlySeen() {
        let now = at(h0, 30 * minute)
        var hours = (h0 - 200 ..< h0 - 30).map { watched($0, uploads: 1) }
        hours += (h0 - 30 ..< h0).filter { !(h0 - 20 ..< h0 - 14).contains($0) }.map { watched($0, stuckFor: 3600) }
        hours.append(watched(h0, stuckFor: 1800, seconds: 1800))
        let live = HistoryLatest(stuck: 2, failing: 0, at: now)
        let line = HistoryLine.make(hours: hours, latest: live, now: now, calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "Uploads seen on 6 of the last 7 days; stalls seen since yesterday. Velum wasn’t watching for 6 hours of that.")
        #expect(line.stallNote == "Stalls seen since yesterday")
    }

    @Test func aShortStallIsSpokenButNotNoted() {
        let now = at(h0, 30 * minute)
        var hours = (h0 - 200 ..< h0 - 3).map { watched($0, uploads: 1) }
        hours += (h0 - 3 ..< h0).map { watched($0, stuckFor: 3600) }
        hours.append(watched(h0, stuckFor: 1800, seconds: 1800))
        let line = HistoryLine.make(hours: hours, latest: HistoryLatest(stuck: 1, failing: 0, at: now), now: now,
                                    calendar: utc, stuckAfter: stuckAfter)
        #expect(normalized(line.summary) == "Uploads seen on 7 of the last 7 days; stalled since 5 AM.")
        #expect(line.stallNote == nil)
    }

    @Test func failingNow() {
        let now = at(h0, 30 * minute)
        var hours = (h0 - 200 ..< h0 - 80).map { watched($0, uploads: 1) }
        hours += (h0 - 80 ... h0).map { watched($0, failing: 1, seconds: $0 == h0 ? 1800 : 3600) }
        let line = HistoryLine.make(hours: hours, latest: HistoryLatest(stuck: 0, failing: 1, at: now), now: now,
                                    calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "Uploads seen on 3 of the last 7 days; uploads failing since Tuesday.")
    }

    @Test func stuckBesideUploadsIsSaidInWords() {
        let now = at(h0, 30 * minute)
        var hours = (h0 - 200 ..< h0).map { watched($0, uploads: 1) }
        hours[hours.count - 5].stuckFor = 1200
        let line = HistoryLine.make(hours: hours, latest: nil, now: now, calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "Uploads seen on 7 of the last 7 days. Files waited past 10 minutes on 1 day.")
    }
}

// MARK: - Hours Velum wasn't running

@MainActor @Suite struct NotWatched {
    @Test func hoursWithoutVelumStayBlank() {
        let r = Recorder()
        defer { r.cleanUp() }
        let one = snapshot([account()])
        r.drive(one, from: at(h0), to: at(h0, hour))                       // 08:00–09:00
        r.drive(one, from: at(h0 + 4), to: at(h0 + 4, 30 * minute))        // back at 12:00, nothing between
        #expect(r.history.hours(for: "Personal").map(\.hour) == [h0, h0 + 1, h0 + 4])
        #expect(r.history.hours(for: "Personal")[1].watched == 0)          // only the 09:00 refresh itself
        let line = r.history.line(for: "Personal", now: at(h0 + 4, 30 * minute), calendar: utc)
        let drawn = Set(line.cells.filter { $0.kind != .unwatched }.map(\.from))
        #expect(line.cells.filter { $0.kind == .quiet }.count == 2)
        #expect(drawn.count == 2)
        #expect(line.summary.hasSuffix("Velum wasn’t watching for 3 hours of that."))
        // Those hours are blank, never quiet.
        #expect(r.history.hours(for: "Personal")[1].kind() == .unwatched)
    }

    @Test func sleepAndLongStepsAreNotWatched() {
        let r = Recorder()
        defer { r.cleanUp() }
        let one = snapshot([account()])
        r.history.record(one, uploaded: [:], now: at(h0), stuckAfter: stuckAfter)
        r.history.pause()                                                  // the Mac went to sleep
        r.history.record(one, uploaded: [:], now: at(h0, 120), stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal")[0].watched == 0)
        r.history.record(one, uploaded: [:], now: at(h0, 150), stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal")[0].watched == 30)
        r.history.record(one, uploaded: [:], now: at(h0, 150 + History.maxStep + 1), stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal")[0].watched == 30)
    }

    @Test func aMostlyUnwatchedHourIsNotQuiet() {
        #expect(watched(h0, seconds: 20 * 60).kind() == .unwatched)
        #expect(watched(h0, seconds: 31 * 60).kind() == .quiet)
        // The current hour is judged on the part that has passed.
        #expect(watched(h0, seconds: 9 * 60).kind(elapsed: 10 * 60) == .quiet)
    }

    @Test func gapsMakeAnHourUnsure() {
        #expect(watched(h0, gap: 10 * 60).kind() == .unsure)
        #expect(watched(h0, gap: 5).kind() == .quiet)                      // "not watching yet" for a moment
        #expect(watched(h0, gap: 5).hadGap)
        let hours = (h0 - 200 ..< h0).map { watched($0, uploads: $0 % 3 == 0 ? 1 : 0, gap: $0 == h0 - 30 ? 900 : 0) }
        let line = HistoryLine.make(hours: hours, latest: nil, now: at(h0, 10), calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "Uploads seen on 7 of the last 7 days. Velum may have missed changes on 1 day.")
    }

    @Test func coverageAndStatusAreRecordedAsSeconds() {
        let r = Recorder()
        defer { r.cleanUp() }
        let unsure = Fixture.status(Fixture.evidence(Fixture.oneDrive()), uploads: UploadSummary(coverageGap: true))
        r.drive(snapshot([unsure]), from: at(h0), to: at(h0, 10 * minute))
        let h = r.history.hours(for: "Personal")[0]
        #expect(h.gap == 600 && h.hadGap)
        #expect(h.unknown == 600 && h.wasUnknown)
        // A sync app that isn't running is not a coverage gap.
        let stopped = Fixture.status(Fixture.evidence(Fixture.oneDrive(), running: false))
        let s = Recorder()
        defer { s.cleanUp() }
        s.drive(snapshot([stopped]), from: at(h0), to: at(h0, 10 * minute))
        #expect(s.history.hours(for: "Personal")[0].gap == 0)
    }
}

// MARK: - The file holds counts only

@MainActor @Suite struct HistoryFile {
    @Test func noFileNamesInTheWrittenFile() throws {
        let r = Recorder()
        defer { r.cleanUp() }
        let folder = "/Users/test/Library/CloudStorage/OneDrive-Personal"
        let failing = account(UploadSummary(waiting: 2, failed: ["Quarterly Budget.xlsx: The file name is too long."]))
        var s = snapshot([failing], stuck: ["Personal": 3])
        s.stuck.files = [PendingFile(account: "Personal", path: "\(folder)/Private/Tax Return 2026.pdf",
                                     since: Fixture.now.addingTimeInterval(-hour), status: .waiting)]
        s.activity = [Activity(accountKey: "Personal", path: "\(folder)/Private/Secret Plan.docx", name: "Secret Plan.docx",
                               kind: History.downloadedKind, date: at(h0, 90), app: "Finder"),
                      Activity(accountKey: "Personal", path: "\(folder)/Holiday.heic", name: "Holiday.heic",
                               kind: Activity.uploaded, date: at(h0, 95), app: nil)]
        r.drive(s, from: at(h0), to: at(h0, 10 * minute)) { _ in ["Personal": 4] }
        let text = try r.text()
        for name in ["Secret Plan", "Tax Return", "Quarterly Budget", "Holiday", ".docx", ".pdf", ".xlsx", ".heic",
                     "/Users", "Private", "CloudStorage", "OneDrive-Personal", "Finder", "too long"] {
            #expect(!text.contains(name), "\(name) leaked into the history file")
        }
        // Only the account's key, numbers and the known field names.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["version", "accounts"])
        let accounts = try #require(json["accounts"] as? [String: [[String: Int]]])
        #expect(Array(accounts.keys) == ["Personal"])
        let fields: Set<String> = ["hour", "watched", "uploads", "reported", "downloads", "waiting", "stuck", "stuckFor", "failing", "gap", "unknown"]
        for record in accounts["Personal"] ?? [] { #expect(Set(record.keys).isSubset(of: fields)) }
        #expect(r.history.hours(for: "Personal").first?.downloads == 1)
        #expect(r.history.hours(for: "Personal").first?.uploads == 4)
        #expect(r.history.hours(for: "Personal").first?.reported == 1)
        #expect(r.history.hours(for: "Personal").first?.uploaded == 4)
    }

    @Test func oneDrivesOwnHistoryCatchesUploadsTooFastToSee() {
        // OneDrive sent a small file up in about two seconds, before the tracker's first look (seen live).
        let r = Recorder()
        defer { r.cleanUp() }
        let start = at(h0, 10 * minute)
        func upload(_ key: String, _ name: String, _ seconds: TimeInterval) -> Activity {
            Activity(accountKey: key, path: "/Users/test/Cloud/\(name)", name: name, kind: Activity.uploaded,
                     date: start.addingTimeInterval(seconds), app: nil)
        }
        let iCloud = account(config: Fixture.iCloud())
        let both = [account(), iCloud]
        let entries = [upload("Personal", "a.txt", 5), upload("Personal", "b.txt", 6), upload(ICloudProvider.key, "c.txt", 7)]
        r.history.record(snapshot(both), uploaded: [:], now: start, stuckAfter: stuckAfter)
        r.history.record(snapshot(both, activity: entries), uploaded: [:], now: start.addingTimeInterval(30), stuckAfter: stuckAfter)
        let personal = r.history.hours(for: "Personal")[0]
        #expect(personal.uploads == 0 && personal.reported == 2)
        #expect(personal.uploaded == 2)
        #expect(personal.kind(elapsed: 40 * 60) == .active)
        // iCloud keeps no history of its own: its Recent entries are the tracker's, never counted twice.
        #expect(r.history.hours(for: ICloudProvider.key)[0].reported == 0)
        // The same uploads seen by both: the larger count, not the sum.
        r.history.record(snapshot(both, activity: entries), uploaded: ["Personal": 2], now: start.addingTimeInterval(60), stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal")[0].uploaded == 2)
    }

    @Test func downloadsAreCountedOnceAndOnlyFromWhenVelumStarted() {
        let r = Recorder()
        defer { r.cleanUp() }
        let start = at(h0, 10 * minute)
        func download(_ name: String, _ date: Date) -> Activity {
            Activity(accountKey: "Personal", path: "/Users/test/OneDrive/\(name)", name: name, kind: History.downloadedKind,
                     date: date, app: nil)
        }
        let before = download("a.txt", start.addingTimeInterval(-60))
        let b = download("b.txt", start.addingTimeInterval(20)), c = download("c.txt", start.addingTimeInterval(20))
        let one = [account()]
        r.history.record(snapshot(one, activity: [before]), uploaded: [:], now: start, stuckAfter: stuckAfter)
        r.history.record(snapshot(one, activity: [b, before]), uploaded: [:], now: start.addingTimeInterval(30), stuckAfter: stuckAfter)
        r.history.record(snapshot(one, activity: [c, b, before]), uploaded: [:], now: start.addingTimeInterval(60), stuckAfter: stuckAfter)
        r.history.record(snapshot(one, activity: [c, b, before]), uploaded: [:], now: start.addingTimeInterval(90), stuckAfter: stuckAfter)
        #expect(r.history.hours(for: "Personal").first?.downloads == 2)
    }
}

// MARK: - The words and the layout

@Suite struct HistoryWords {
    @Test func noRecordsYet() {
        let line = HistoryLine.make(hours: [], latest: nil, now: Fixture.now, calendar: utc, stuckAfter: stuckAfter)
        #expect(line.summary == "No sync history yet.")
        #expect(line.tooltip == "No sync history yet.")
        #expect(line.cells.isEmpty)
    }

    @Test func weekAndShortHistory() {
        let now = at(h0, 10)
        let week = (h0 - 200 ... h0).map { watched($0, uploads: $0 % 24 == 3 && $0 != h0 - 5 ? 2 : 0) }   // none on Friday
        #expect(HistoryLine.make(hours: week, latest: nil, now: now, calendar: utc).summary
                == "Uploads seen on 6 of the last 7 days.")
        let none = (h0 - 200 ... h0).map { watched($0) }
        #expect(HistoryLine.make(hours: none, latest: nil, now: now, calendar: utc).summary
                == "No uploads seen in the last 7 days.")
        // History began on Wednesday: three days so far, with uploads on two.
        let short = (h0 - 50 ... h0).map { watched($0, uploads: $0 % 24 == 3 ? 1 : 0) }
        #expect(HistoryLine.make(hours: short, latest: nil, now: now, calendar: utc).summary
                == "Uploads seen on 2 of the 3 days since history began.")
        #expect(HistoryLine.make(hours: [watched(h0 - 1, uploads: 1)], latest: nil, now: now, calendar: utc).summary
                == "Uploads seen today, since history began.")
        #expect(HistoryLine.make(hours: [watched(h0 - 1)], latest: nil, now: now, calendar: utc).summary
                == "No uploads seen since history began today.")
    }

    @Test func sinceWords() {
        let now = at(h0, 30 * minute)                                   // Friday 08:30 UTC
        #expect(normalized(HistoryLine.since(h0 - 3, now: now, calendar: utc)) == "5 AM")
        #expect(HistoryLine.since(h0 - 20, now: now, calendar: utc) == "yesterday")
        #expect(HistoryLine.since(h0 - 3 * 24, now: now, calendar: utc) == "Tuesday")
        #expect(HistoryLine.since(h0 - 10 * 24, now: now, calendar: utc) == "Jan 5")
    }

    @Test func waitingSinceSaysTheDayWhenNotToday() {
        let now = at(h0, 30 * minute)                                   // Friday 08:30 UTC
        #expect(normalized(RelTime.clockWithDay(at(h0, 15 * minute), now: now, calendar: utc)) == "8:15 AM")
        #expect(normalized(RelTime.clockWithDay(at(h0 - 20), now: now, calendar: utc)) == "yesterday 12:00 PM")
        #expect(normalized(RelTime.clockWithDay(at(h0 - 3 * 24, 45 * minute), now: now, calendar: utc)) == "Tue 8:45 AM")
        #expect(RelTime.clockWithDay(at(h0 - 10 * 24), now: now, calendar: utc) == "Jan 5")
    }

    @Test func unwatchedTimeWords() {
        #expect(HistoryLine.hoursText(3600) == "1 hour")
        #expect(HistoryLine.hoursText(31 * 3600 + 100) == "31 hours")
        #expect(HistoryLine.hoursText(60 * 3600) == "about 3 days")
    }

    @Test func tooltipSaysQuietIsNotUpToDate() {
        let line = HistoryLine.make(hours: (h0 - 200 ... h0).map { watched($0) }, latest: nil, now: at(h0, 10), calendar: utc,
                                    stuckAfter: stuckAfter)
        #expect(line.tooltip == "Last 7 days, oldest on the left; today is partial. No uploads seen in the last 7 days. A flat line means no uploads and nothing waiting 10 minutes or more. It doesn’t mean up to date.")
        #expect(HistoryLine.legend(waitMinutes: 10).contains("It is never green"))
    }

    @Test func sevenLocalDaysWithTodayOnlySoFar() {
        let now = at(h0, 30 * minute)                                   // 08:30, so today has 9 hours so far
        let line = HistoryLine.make(hours: (h0 - 300 ... h0).map { watched($0) }, latest: nil, now: now, calendar: utc)
        #expect(Set(line.cells.map(\.day)) == Set(0..<7))
        #expect(line.cells.filter { $0.day < 6 }.count == 6 * 24)
        #expect(line.cells.filter { $0.day == 6 }.count == 9)
        #expect(line.cells.allSatisfy { 0 <= $0.from && $0.from < $0.to && $0.to <= 1 })
        // History that began on Thursday leaves the days before it blank.
        let short = HistoryLine.make(hours: (h0 - 30 ... h0).map { watched($0) }, latest: nil, now: now, calendar: utc)
        #expect(Set(short.cells.map(\.day)) == [5, 6])
    }

    @Test func aDaylightSavingDayKeepsAllItsHours() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        newYork.locale = Locale(identifier: "en_US")
        // November 1, 2026: clocks go back, so the day has 25 hours.
        let day = try #require(newYork.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let next = try #require(newYork.date(byAdding: .day, value: 1, to: day))
        #expect(next.timeIntervalSince(day) == 25 * 3600)
        let now = next.addingTimeInterval(12 * 3600)
        let hours = (HistoryHour.hour(of: day) - 24 ... HistoryHour.hour(of: now)).map { watched($0) }
        let line = HistoryLine.make(hours: hours, latest: nil, now: now, calendar: newYork)
        let cells = line.cells.filter { $0.day == 5 }
        #expect(cells.count == 25)
        #expect(cells.first?.from == 0)
        #expect(abs((cells.last?.to ?? 0) - 1) < 1e-9)
    }
}

/// Newer ICU puts a narrow no-break space before "AM"; compare with a plain space.
private func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{202F}", with: " ")
}
