import SwiftUI

/// Card A6: an account's last 7 days as a 3 pt strip in the row's bottom padding, so the row keeps its height
/// (Codex and Fable both chose this over a sparkline beside the name or on the source line). Hour by hour on
/// local calendar days, with a 1 pt break at each midnight; today ends at the current hour.
///
/// Marks, as Fable ruled them (no counts in the height, and never green: history can't show an account is
/// up to date):
/// - quiet: a 1 pt baseline, `primary` at 22%;
/// - uploads: the full 3 pt, `primary` at 60%;
/// - stalled: the full 3 pt in orange, 3 pt on and 1 pt off from the run's left edge, so it differs from
///   failing by shape as well as hue (Codex);
/// - failing: solid red;
/// - not watched, may have missed changes, before history began, still to come: nothing.
/// VoiceOver reads the line's summary in the row's own value, so the strip itself is hidden from it.
struct SparklineView: View {
    let line: HistoryLine

    var body: some View {
        Canvas { context, size in
            Self.draw(line.cells, in: &context, size: size)
        }
        .frame(height: 3)
        .padding(.top, 5)               // an 8 pt band to hover for the tooltip
        .contentShape(Rectangle())
        .help(line.tooltip)
        .accessibilityHidden(true)
        // Under the row's lines block: 46 pt in (the row's 8 plus the lines' 38), 10 pt from the trailing
        // edge (2 plus 8), 1 pt above the row's bottom edge: x 52–324 in the 340 pt panel.
        .padding(.leading, 46)
        .padding(.trailing, 10)
        .padding(.bottom, 1)
    }

    static func draw(_ cells: [HistoryLine.Cell], in context: inout GraphicsContext, size: CGSize) {
        let days = CGFloat(HistoryLine.windowDays)
        let dayWidth = (size.width - (days - 1)) / days
        // Half-point steps land on whole pixels on a Retina screen.
        func x(_ day: Int, _ fraction: Double) -> CGFloat {
            ((CGFloat(day) * (dayWidth + 1) + CGFloat(fraction) * dayWidth) * 2).rounded() / 2
        }
        var quiet = Path(), active = Path(), stalled = Path(), failing = Path()
        // Neighbouring hours of the same class become one rectangle, so no seams show between them.
        var i = 0
        while i < cells.count {
            let first = cells[i]
            var j = i
            while j + 1 < cells.count, cells[j + 1].day == first.day, cells[j + 1].kind == first.kind,
                  abs(cells[j + 1].from - cells[j].to) < 1e-9 {
                j += 1
            }
            let x0 = x(first.day, first.from), x1 = x(first.day, cells[j].to)
            let full = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            switch first.kind {
            case .quiet:
                quiet.addRect(CGRect(x: x0, y: size.height - 1, width: x1 - x0, height: 1))
            case .active:
                active.addRect(full)
            case .failing:
                failing.addRect(full)
            case .stalled:
                var s = x0
                while s < x1 {
                    // A run's last fragment under 2 pt looks like a glitch (Fable): leave it out, unless it's all there is.
                    let width = min(3, x1 - s)
                    if width >= 2 || s == x0 {
                        stalled.addRect(CGRect(x: s, y: 0, width: width, height: size.height))
                    }
                    s += 4
                }
            case .unwatched, .unsure:
                break
            }
            i = j + 1
        }
        context.fill(quiet, with: .color(.primary.opacity(0.22)))
        context.fill(active, with: .color(.primary.opacity(0.6)))
        context.fill(stalled, with: .color(.orange))
        context.fill(failing, with: .color(.red))
    }
}

/// Made-up history for renders (`Velum --render-panel out.png --sample <name> [--sample-stall]`), so a shared
/// picture never shows this Mac's own: a usual week, awake 8 AM to midnight with the nights not watched, a
/// morning away now and then, uploads on most days, one coverage gap and one short failure.
/// `--sample-stall` makes the second account stalled for two days, with three files waiting in its row.
@MainActor
enum HistorySample {
    static func apply(to snapshot: inout Snapshot, stall: Bool, now: Date = Date(), calendar: Calendar = .current) {
        let nowHour = HistoryHour.hour(of: now)
        var records: [String: [HistoryHour]] = [:]
        var latest: [String: HistoryLatest] = [:]
        for (index, account) in snapshot.accounts.enumerated() {
            var hours: [HistoryHour] = []
            for hour in (nowHour - 9 * 24)...nowHour {
                let start = HistoryHour.start(of: hour)
                let local = calendar.component(.hour, from: start)
                let day = calendar.ordinality(of: .day, in: .era, for: start) ?? 0
                guard local >= 8 || hour > nowHour - 4 else { continue }    // asleep, unless it's the last few hours
                if (day + index) % 5 == 0, local < 13 { continue }          // a morning away from the Mac
                var record = HistoryHour(hour: hour)
                record.watched = HistoryHour.elapsed(hour, now: now)
                let roll = (hour &* 7919 &+ index &* 104_729) % 13
                if roll < 3, (day + index) % 4 != 1 {
                    record.uploads = roll + 1
                    record.waiting = roll + 1
                }
                let daysAgo = calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                                      to: calendar.startOfDay(for: now)).day ?? 0
                if index == 2, daysAgo == 3, local == 15 { record.gap = 1500 }
                if index == 3, daysAgo == 4, local == 11 || local == 12 { record.failing = 1 }
                hours.append(record)
            }
            records[account.id] = hours
            latest[account.id] = HistoryLatest(stuck: 0, failing: 0, at: now)
        }
        if stall, snapshot.accounts.count > 1 {
            let account = snapshot.accounts[1]
            let since = nowHour - 50
            var uploads = UploadSummary()
            uploads.waiting = 3
            uploads.oldestWaiting = HistoryHour.start(of: since).addingTimeInterval(-15 * 60)
            snapshot.accounts[1] = Collector.status(AccountEvidence(config: account.config, name: account.name),
                                                    transfer: nil, uploads: uploads, watchingUploads: true, now: now)
            records[account.id] = records[account.id]?.map { (hour: HistoryHour) -> HistoryHour in
                guard hour.hour >= since else { return hour }
                var stalled = HistoryHour(hour: hour.hour)
                stalled.watched = hour.watched
                stalled.waiting = 3
                stalled.stuck = 3
                stalled.stuckFor = hour.watched
                return stalled
            }
            latest[account.id] = HistoryLatest(stuck: 3, failing: 0, at: now)
        }
        History.shared.showSample(records, latest: latest)
        for account in snapshot.accounts {
            let line = History.shared.line(for: account.id, now: now, calendar: calendar)
            print("History sample · \(account.name): \(line.summary)\(line.stallNote.map { " [row: \($0)]" } ?? "")")
        }
    }
}
