import AppKit
import Combine

// Card A6: sync history per account. One record per account per hour, kept 30 days in
// ~/Library/Application Support/Velum/history.json on this Mac only. Counts and seconds only: never a file
// name, a path or a folder. Every account of every service is recorded the same way, from the snapshot the
// panel shows, so a service added later gets a history with no extra code.
//
// Hours Velum didn't see (it wasn't running, or the Mac was asleep) are never filled in: they stay "not
// watched", and the strip draws nothing there. The look and the words were set by the Codex and Fable
// consult (see the card's hand-off).

/// What Velum saw of one account during one clock hour.
struct HistoryHour: Codable, Equatable {
    /// Hours since 1970-01-01 00:00 UTC. Laid out by local day only when drawn, so a time-zone or
    /// daylight-saving change never creates or deletes an hour.
    let hour: Int
    /// Seconds Velum was running, the Mac awake, and the account present.
    var watched = 0
    /// Uploads Velum saw finish: a changed file seen waiting or uploading, then in the cloud.
    var uploads = 0
    /// Uploads the service's own history reported (OneDrive). OneDrive can send a small file up in about two
    /// seconds, before Velum's first look, so its own record catches what the tracker misses.
    var reported = 0
    /// Downloads the service's own history reported (OneDrive; the others keep none Velum can read).
    var downloads = 0
    /// The most files waiting or uploading at once.
    var waiting = 0
    /// The most files waiting past the stuck threshold (10 minutes) at once; a service's own queue holding
    /// work that long counts as one.
    var stuck = 0
    /// Seconds during which at least one file (or the service's queue) had waited past the stuck threshold.
    var stuckFor = 0
    /// The most files failing to upload at once.
    var failing = 0
    /// Seconds Velum may have missed changes (a coverage gap, or not watching the folders yet).
    var gap = 0
    /// Seconds the account's status was unknown.
    var unknown = 0

    init(hour: Int) { self.hour = hour }

    /// The card's "whether coverage had a gap" and "whether the status was unknown".
    var hadGap: Bool { gap > 0 }
    var wasUnknown: Bool { unknown > 0 }

    /// The hour's uploads: the larger of the two counts. Each one only ever misses uploads, never invents
    /// them, so the larger is still never more than happened; adding them would count a file twice.
    var uploaded: Int { max(uploads, reported) }

    /// How long a stall or a coverage gap must last inside an hour before the hour is classed by it.
    static let minimumSpell = 5 * 60

    /// Velum may have missed changes for long enough that it can't call the hour quiet: 5 minutes, or half
    /// of the time it watched.
    var missedChanges: Bool { gap >= Self.minimumSpell || (gap > 0 && gap * 2 >= watched) }

    /// How the hour is drawn and spoken of, worst first. `elapsed`: how much of the hour has passed (all of
    /// it for past hours), so the current hour is judged on its watched share so far.
    func kind(elapsed: Int = 3600) -> HourKind {
        if failing > 0 { return .failing }
        if uploaded == 0, stuckFor >= Self.minimumSpell { return .stalled }
        if uploaded > 0 { return .active }
        if watched * 2 < max(1, elapsed) { return .unwatched }
        if missedChanges { return .unsure }
        return .quiet
    }

    static func hour(of date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    static func start(of hour: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(hour) * 3600)
    }

    /// How much of `hour` has passed by `now`, in seconds, from 1 to 3600.
    static func elapsed(_ hour: Int, now: Date) -> Int {
        min(3600, max(1, Int(now.timeIntervalSince(start(of: hour)).rounded(.down))))
    }

    // Zero fields are left out of the file, which keeps 30 days small; a missing field reads as zero.
    private enum CodingKeys: String, CodingKey {
        case hour, watched, uploads, reported, downloads, waiting, stuck, stuckFor, failing, gap, unknown
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = try c.decode(Int.self, forKey: .hour)
        func int(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        watched = try int(.watched)
        uploads = try int(.uploads)
        reported = try int(.reported)
        downloads = try int(.downloads)
        waiting = try int(.waiting)
        stuck = try int(.stuck)
        stuckFor = try int(.stuckFor)
        failing = try int(.failing)
        gap = try int(.gap)
        unknown = try int(.unknown)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hour, forKey: .hour)
        let fields: [(CodingKeys, Int)] = [(.watched, watched), (.uploads, uploads), (.reported, reported),
                                           (.downloads, downloads),
                                           (.waiting, waiting), (.stuck, stuck), (.stuckFor, stuckFor),
                                           (.failing, failing), (.gap, gap), (.unknown, unknown)]
        for (key, value) in fields where value != 0 { try c.encode(value, forKey: key) }
    }
}

/// An hour's class, worst first.
enum HourKind: Equatable {
    /// A file was failing to upload.
    case failing
    /// Work waited past the stuck threshold for 5 minutes or more, and nothing uploaded that hour (the
    /// owner's definition: work waiting, nothing uploaded).
    case stalled
    /// Uploads finished.
    case active
    /// Velum wasn't running, or the Mac was asleep, for more than half of the hour (so far). Never quiet.
    case unwatched
    /// Watched, but Velum may have missed changes, so it can't call the hour quiet.
    case unsure
    /// Watched, no uploads, nothing waiting past the stuck threshold. Quiet is fine; it isn't "up to date".
    case quiet
}

/// What the last refresh saw of an account, in memory only: "stalled now" and "failing now" are said only
/// from this live evidence, never from the hour records.
struct HistoryLatest: Equatable {
    var stuck: Int
    var failing: Int
    var at: Date
}

// MARK: - The strip and its words

/// The last 7 local calendar days of one account: what the strip draws and the words for it.
struct HistoryLine: Equatable {
    struct Cell: Equatable {
        /// 0 is six days ago, 6 is today.
        let day: Int
        /// Where the hour starts and ends within its local day, from 0 to 1.
        let from: Double
        let to: Double
        let kind: HourKind
    }

    static let windowDays = 7
    static let noHistory = "No sync history yet."

    /// Hours with a record, in order. Hours before history began, still to come today, or never recorded
    /// (Velum not running) have no cell: the strip leaves them blank.
    var cells: [Cell] = []
    /// VoiceOver's words after the row's own, and the tooltip's middle: "Uploads seen on 6 of the last 7
    /// days."
    var summary = HistoryLine.noHistory
    /// Put before the row's source line for a stall of a day or more: "Stalled for 2 days, since Tuesday".
    var stallNote: String?
    /// The stuck threshold in minutes, for the words.
    var waitMinutes = 10

    var tooltip: String {
        guard summary != Self.noHistory else { return summary }
        return "Last 7 days, oldest on the left; today is partial. \(summary) A flat line means no uploads and nothing waiting \(waitMinutes) minutes or more. It doesn’t mean up to date."
    }

    /// The legend's row for the strip (card A6, Fable's words).
    static func legend(waitMinutes: Int) -> String {
        "The line under an account: its last 7 days, hour by hour. Tall marks: uploads Velum saw finish or OneDrive recorded. Broken orange: files waited \(waitMinutes) minutes or more and nothing uploaded. Red: uploads failing. Flat: no uploads and nothing waiting that long. Blank: Velum wasn’t watching, or may have missed changes. It is never green: history can’t show an account is up to date."
    }

    private struct Day {
        var counted = false
        var uploads = false
        var missed = false
        var stuckBesideUploads = false
    }

    /// Builds the line from an account's hours (oldest first). `latest` is the last refresh's live evidence,
    /// or nil when there is none recent.
    static func make(hours: [HistoryHour], latest: HistoryLatest?, now: Date, calendar: Calendar = .current,
                     stuckAfter: TimeInterval = UploadTracker.stuckAfter) -> HistoryLine {
        var line = HistoryLine()
        line.waitMinutes = max(1, Int(stuckAfter / 60))
        let nowHour = HistoryHour.hour(of: now)
        guard let first = hours.first?.hour, first <= nowHour else { return line }
        let byHour = Dictionary(hours.map { ($0.hour, $0) }, uniquingKeysWith: { a, _ in a })
        let today = calendar.startOfDay(for: now)
        // The starts of the 7 days, plus tomorrow's, to bound today.
        let starts = (0...windowDays).compactMap { calendar.date(byAdding: .day, value: $0 - (windowDays - 1), to: today) }
        guard starts.count == windowDays + 1 else { return line }

        var days = Array(repeating: Day(), count: windowDays)
        var unwatched = 0
        for d in 0..<windowDays {
            let start = starts[d], end = starts[d + 1]
            let length = end.timeIntervalSince(start)
            // Each hour belongs to the day it starts in; a half-hour time zone's hour straddles midnight.
            var hour = Int((start.timeIntervalSince1970 / 3600).rounded(.up))
            while HistoryHour.start(of: hour) < end, hour <= nowHour {
                defer { hour += 1 }
                guard hour >= first else { continue }   // before history began: blank, and not counted
                days[d].counted = true
                let elapsed = HistoryHour.elapsed(hour, now: now)
                let record = byHour[hour]
                // History begins partway through its first hour; the part before isn't "not watching".
                if hour > first { unwatched += max(0, elapsed - (record?.watched ?? 0)) }
                guard let record else { continue }
                let from = HistoryHour.start(of: hour).timeIntervalSince(start) / length
                let to = min(1, HistoryHour.start(of: hour + 1).timeIntervalSince(start) / length)
                line.cells.append(Cell(day: d, from: from, to: to, kind: record.kind(elapsed: elapsed)))
                if record.uploaded > 0 { days[d].uploads = true }
                if record.missedChanges { days[d].missed = true }
                if record.uploaded > 0, record.stuckFor >= HistoryHour.minimumSpell { days[d].stuckBesideUploads = true }
            }
        }

        let counted = days.filter(\.counted).count
        let uploadDays = days.filter(\.uploads).count
        var sentence: String
        if counted >= windowDays {
            sentence = uploadDays == 0 ? "No uploads seen in the last 7 days" : "Uploads seen on \(uploadDays) of the last 7 days"
        } else if counted <= 1 {
            sentence = uploadDays == 0 ? "No uploads seen since history began today" : "Uploads seen today, since history began"
        } else {
            sentence = uploadDays == 0 ? "No uploads seen in the \(counted) days since history began"
                : "Uploads seen on \(uploadDays) of the \(counted) days since history began"
        }
        let current = byHour[nowHour]
        if let latest, latest.failing > 0 {
            let run = Self.run(of: .failing, byHour: byHour, first: first, now: now)
            sentence += "; uploads failing since \(since(run.start, now: now, calendar: calendar))"
        } else if let latest, latest.stuck > 0, (current?.uploaded ?? 0) == 0 {
            let run = Self.run(of: .stalled, byHour: byHour, first: first, now: now)
            let when = since(run.start, now: now, calendar: calendar)
            sentence += run.bridged ? "; stalls seen since \(when)" : "; stalled since \(when)"
            let length = now.timeIntervalSince(HistoryHour.start(of: run.start))
            if length >= 86_400 {
                line.stallNote = run.bridged ? "Stalls seen since \(when)" : "Stalled for \(Reasons.duration(length)), since \(when)"
            }
        }
        var parts = [sentence + "."]
        if unwatched >= 3600 { parts.append("Velum wasn’t watching for \(hoursText(unwatched)) of that.") }
        let missed = days.filter(\.missed).count
        if missed > 0 { parts.append("Velum may have missed changes on \(daysText(missed)).") }
        let stuckBeside = days.filter(\.stuckBesideUploads).count
        if stuckBeside > 0 { parts.append("Files waited past \(line.waitMinutes) minutes on \(daysText(stuckBeside)).") }
        line.summary = parts.joined(separator: " ")
        return line
    }

    /// Walks back from the current hour through hours of `kind`; hours Velum didn't see, or couldn't vouch
    /// for, don't end the run but make it "bridged" (counts can't prove the same files waited throughout).
    /// Any other hour ends it. The start is the run's earliest hour of `kind`, or the current hour.
    static func run(of kind: HourKind, byHour: [Int: HistoryHour], first: Int, now: Date) -> (start: Int, bridged: Bool) {
        let nowHour = HistoryHour.hour(of: now)
        var start = nowHour
        var bridged = false
        var crossing = false
        var hour = nowHour - 1
        while hour >= first {
            let k = byHour[hour]?.kind() ?? .unwatched
            if k == kind {
                start = hour
                if crossing { bridged = true; crossing = false }
            } else if k == .unwatched || k == .unsure {
                crossing = true
            } else {
                break
            }
            hour -= 1
        }
        return (start, bridged)
    }

    /// "2 PM" today, "yesterday", "Tuesday" within the week, "Oct 28" before that.
    static func since(_ hour: Int, now: Date, calendar: Calendar) -> String {
        let date = HistoryHour.start(of: hour)
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return date.formatted(style.hour())
        case 1: return "yesterday"
        case 2..<7: return date.formatted(style.weekday(.wide))
        default: return date.formatted(style.month(.abbreviated).day())
        }
    }

    static func hoursText(_ seconds: Int) -> String {
        let hours = seconds / 3600
        if hours < 48 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        return "about \(Int((Double(seconds) / 86_400).rounded())) days"
    }

    static func daysText(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
}

extension RelTime {
    /// "2:15 PM" today, "yesterday 2:15 PM", "Wed 2:15 PM" within the week, "Nov 5" before that. For "waiting
    /// since", which beside a stall of days ("Stalls seen since Wednesday") must not read as this afternoon.
    static func clockWithDay(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let style = Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return date.formatted(style.hour().minute())
        case 1: return "yesterday " + date.formatted(style.hour().minute())
        case 2..<7: return date.formatted(style.weekday(.abbreviated).hour().minute())
        default: return date.formatted(style.month(.abbreviated).day())
        }
    }
}

// MARK: - Recording and keeping

@MainActor
final class History: ObservableObject {
    static let shared = History(observeSystem: true)

    /// The owner's decision: 30 days, on this Mac only.
    static let keepDays = 30
    static var keepHours: Int { keepDays * 24 }
    /// The longest step between two refreshes still counted as watched. A longer one means Velum was stopped
    /// or the Mac slept through it (sleep is also caught directly), so that time stays "not watched".
    static let maxStep: TimeInterval = 5 * 60
    static let saveEvery: TimeInterval = 5 * 60
    /// Activity's code for "Downloaded" (OneDrive's history_list item type 4).
    static let downloadedKind = 4

    nonisolated static var defaultFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Velum/history.json")
    }

    /// Bumped when something the strip draws changes (not on every second watched), so rows redraw rarely.
    @Published private(set) var revision = 0

    /// Each account's hours, oldest first, by the account's key.
    private(set) var records: [String: [HistoryHour]] = [:]
    let file: URL?
    private(set) var latest: [String: HistoryLatest] = [:]

    private var lastSample: Date?
    private var started: Date?
    private var currentHour: Int?
    private var uploadTotals: [String: Int] = [:]
    private var entryMarks: [String: (date: Date, ids: Set<String>)] = [:]
    private var dirty = false
    private var lastSave: Date?
    /// Showing made-up hours for a render: never recorded into, never saved.
    private var readOnly = false
    private var observers: [NSObjectProtocol] = []
    private let writeQueue = DispatchQueue(label: "Velum.history", qos: .utility)

    private struct Stored: Codable {
        var version = 1
        var accounts: [String: [HistoryHour]]
    }

    init(file: URL? = History.defaultFile, now: Date = Date(), observeSystem: Bool = false) {
        self.file = file
        if let file { load(file, now: now) }
        if observeSystem { observe() }
    }

    func hours(for key: String) -> [HistoryHour] { records[key] ?? [] }

    /// The strip and words for one account, with "now" said only from a refresh in the last 5 minutes.
    func line(for key: String, now: Date = Date(), calendar: Calendar = .current) -> HistoryLine {
        let live = latest[key].flatMap { now.timeIntervalSince($0.at) <= Self.maxStep ? $0 : nil }
        return HistoryLine.make(hours: hours(for: key), latest: live, now: now, calendar: calendar)
    }

    // MARK: Recording

    /// Called after every refresh with what the panel shows and the tracker's running count of uploads it
    /// saw finish per account. Credits the time since the last refresh as watched (split at the hour), and
    /// keeps each hour's most-at-once counts.
    func record(_ snapshot: Snapshot, uploaded: [String: Int], now: Date = Date(),
                stuckAfter: TimeInterval = UploadTracker.stuckAfter) {
        guard !readOnly else { return }
        let started = self.started ?? now
        self.started = started
        let hourNow = HistoryHour.hour(of: now)
        var credit: [(hour: Int, seconds: Int)] = []
        if let last = lastSample, now > last, now.timeIntervalSince(last) <= Self.maxStep {
            credit = Self.split(from: last, to: now)
        }
        lastSample = now
        var changed = false
        if currentHour != hourNow {
            changed = currentHour != nil
            currentHour = hourNow
            prune(now: now)
        }

        for account in snapshot.accounts {
            let key = account.id
            let stuck = Self.stuckWork(account, list: snapshot.stuck, now: now, after: stuckAfter)
            let gap = account.state != .notRunning && !account.uploadsCovered
            let unknown = account.state == .unknown
            let total = uploaded[key] ?? 0
            let previous = uploadTotals[key] ?? 0
            let newUploads = total >= previous ? total - previous : total
            uploadTotals[key] = total
            let downloads = newEntries(key, kind: Self.downloadedKind, activity: snapshot.activity, since: started)
            let reported = account.config.keepsOwnHistory
                ? newEntries(key, kind: Activity.uploaded, activity: snapshot.activity, since: started) : [:]

            var hours = records[key] ?? []
            let before = Self.visible(hours.suffix(2), now: now)
            for part in credit {
                Self.update(&hours, part.hour) { h in
                    h.watched += part.seconds
                    if gap { h.gap += part.seconds }
                    if unknown { h.unknown += part.seconds }
                    if stuck > 0 { h.stuckFor += part.seconds }
                }
            }
            Self.update(&hours, hourNow) { h in
                h.waiting = max(h.waiting, account.uploadsPending)
                h.stuck = max(h.stuck, stuck)
                h.failing = max(h.failing, account.uploadsFailed)
                h.uploads += newUploads
            }
            for (hour, count) in downloads {
                Self.update(&hours, hour) { $0.downloads += count }
            }
            for (hour, count) in reported {
                Self.update(&hours, hour) { $0.reported += count }
            }
            let seen = HistoryLatest(stuck: stuck, failing: account.uploadsFailed, at: now)
            let was = latest[key]
            if Self.visible(hours.suffix(2), now: now) != before
                || ((was?.stuck ?? 0) > 0) != (stuck > 0) || ((was?.failing ?? 0) > 0) != (account.uploadsFailed > 0) {
                changed = true
            }
            records[key] = hours
            latest[key] = seen
        }
        dirty = true
        if changed { revision += 1 }
        if changed || lastSave.map({ now.timeIntervalSince($0) >= Self.saveEvery }) ?? true {
            save(now: now)
        }
    }

    /// The Mac is going to sleep or just woke: the time until the next refresh isn't watched.
    func pause() {
        lastSample = nil
    }

    /// Files (or a service's queue) waiting past the stuck threshold for this account right now. Failing files
    /// are counted apart, so they're taken out of A3's list here.
    nonisolated static func stuckWork(_ account: AccountStatus, list: PendingList, now: Date, after: TimeInterval) -> Int {
        let files = max(0, (list.perAccount[account.id] ?? 0) - account.uploadsFailed)
        let queue = account.workPending && (account.workingSince.map { now.timeIntervalSince($0) >= after } ?? false)
        return max(files, queue ? 1 : 0)
    }

    /// Entries of one kind (downloads, uploads) in the service's own history (OneDrive) newer than the last
    /// ones counted, by hour. Only those dated after Velum started count: Velum doesn't fill in hours from
    /// before it ran. Entry ids stay in memory, never in the file.
    private func newEntries(_ key: String, kind: Int, activity: [Activity], since started: Date) -> [Int: Int] {
        let markKey = "\(kind) \(key)"
        let mark = entryMarks[markKey] ?? (date: started, ids: [])
        var counts: [Int: Int] = [:]
        var newest = mark
        for item in activity where item.accountKey == key && item.kind == kind {
            if item.date < mark.date || (item.date == mark.date && mark.ids.contains(item.id)) { continue }
            counts[HistoryHour.hour(of: item.date), default: 0] += 1
            if item.date > newest.date {
                newest = (item.date, [item.id])
            } else if item.date == newest.date {
                newest.ids.insert(item.id)
            }
        }
        entryMarks[markKey] = newest
        return counts
    }

    // MARK: Hours

    /// Whole seconds from `start` to `end`, split at each hour. They come from whole-second timestamps, so
    /// many short steps add up exactly instead of drifting by rounding.
    nonisolated static func split(from start: Date, to end: Date) -> [(hour: Int, seconds: Int)] {
        var parts: [(hour: Int, seconds: Int)] = []
        var t = Int(start.timeIntervalSince1970.rounded(.down))
        let stop = Int(end.timeIntervalSince1970.rounded(.down))
        while t < stop {
            let hour = t / 3600
            let boundary = min((hour + 1) * 3600, stop)
            parts.append((hour, boundary - t))
            t = boundary
        }
        return parts
    }

    /// Changes an hour's record, adding it in order if it isn't there yet.
    private static func update(_ hours: inout [HistoryHour], _ hour: Int, _ change: (inout HistoryHour) -> Void) {
        var i = hours.count
        while i > 0, hours[i - 1].hour > hour { i -= 1 }
        if i > 0, hours[i - 1].hour == hour {
            change(&hours[i - 1])
        } else {
            var record = HistoryHour(hour: hour)
            change(&record)
            hours.insert(record, at: i)
        }
    }

    /// What the strip shows of the latest hours: each one's class.
    private static func visible(_ hours: ArraySlice<HistoryHour>, now: Date) -> [String] {
        hours.map { "\($0.hour) \($0.kind(elapsed: HistoryHour.elapsed($0.hour, now: now)))" }
    }

    /// Drops hours older than 30 days, and accounts left with none.
    private func prune(now: Date) {
        let oldest = HistoryHour.hour(of: now) - Self.keepHours + 1
        for (key, hours) in records {
            guard let first = hours.first, first.hour < oldest else { continue }
            let kept = hours.filter { $0.hour >= oldest }
            records[key] = kept.isEmpty ? nil : kept
            dirty = true
        }
    }

    // MARK: Saving

    private func load(_ file: URL, now: Date) {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == 1 else {
            debugLog("history", "the sync history file can't be read; starting a new one")
            return
        }
        records = stored.accounts.mapValues { $0.sorted { $0.hour < $1.hour } }
        prune(now: now)
    }

    /// Writes the file atomically, off the main thread. With `wait`, returns only once every write asked for
    /// so far is on disk (at quit, before sleep, and in tests). Counts only, by account key.
    func save(now: Date = Date(), wait: Bool = false) {
        defer { if wait { writeQueue.sync {} } }
        guard let file, !readOnly, dirty else { return }
        dirty = false
        lastSave = now
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Stored(accounts: records)) else { return }
        writeQueue.async {
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                debugLog("history", "couldn't save the sync history: \(error.localizedDescription)")
            }
        }
    }

    /// Saves at quit and before sleep; sleep and wake also keep the time asleep from counting as watched.
    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pause()
                self?.save(wait: true)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(wait: true) }
        })
    }

    // MARK: Sample data

    /// Replaces what's shown with made-up hours, for `Velum --render-panel --sample …`. Nothing is saved.
    func showSample(_ sample: [String: [HistoryHour]], latest: [String: HistoryLatest]) {
        readOnly = true
        records = sample
        self.latest = latest
        revision += 1
    }
}

// MARK: - Live check

/// `Velum --history-probe <seconds> <file.json>`: runs the real sources (accounts, File Provider transfers,
/// the upload tracker) for a while, records into `file`, and prints each account's summary and its last hours.
/// For live checks without replacing the running app: the real history file is never touched.
@MainActor
enum HistoryProbe {
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--history-probe"), i + 2 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        let history = History(file: URL(fileURLWithPath: args[i + 2]))
        let collector = Collector()
        let transfers = TransferMonitor()
        let tracker = UploadTracker()
        var roots: [String: [URL]] = [:]
        var snapshot = Snapshot()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            snapshot = collector.collect(force: roots.isEmpty, transfers: transfers.snapshot(), uploads: tracker.summary())
            snapshot.stuck = tracker.pending(olderThan: UploadTracker.stuckAfter)
            history.record(snapshot, uploaded: tracker.uploadedCounts())
            let next = Dictionary(snapshot.accounts.map { ($0.config.key, $0.config.watchRoots) }, uniquingKeysWith: { a, _ in a })
            if next != roots {
                roots = next
                transfers.watch(roots)
                tracker.watch(roots, recordingUploadsFor: Set(snapshot.accounts.filter { !$0.config.keepsOwnHistory }.map(\.id)))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        }
        history.save(wait: true)
        for account in snapshot.accounts {
            print("• \(account.name): \(account.headline)")
            print("    \(history.line(for: account.id).summary)")
            for hour in history.hours(for: account.id).suffix(3) {
                print("    hour \(HistoryHour.start(of: hour.hour).formatted(date: .abbreviated, time: .shortened)): watched \(hour.watched) s, uploads \(hour.uploads) (its own history: \(hour.reported)), downloads \(hour.downloads), most waiting \(hour.waiting), stuck \(hour.stuck) (\(hour.stuckFor) s), failing \(hour.failing), gap \(hour.gap) s, unknown \(hour.unknown) s → \(hour.kind(elapsed: HistoryHour.elapsed(hour.hour, now: Date())))")
            }
        }
        exit(0)
    }
}
