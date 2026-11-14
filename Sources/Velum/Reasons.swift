import Foundation

/// The reason lines the merge writes itself (A4): the ones no single provider owns. Providers word their own
/// (`AccountEvidence.unknownReason`, `ProviderReport.reason`); these are the shared fallbacks and the
/// tracker's coverage gap.
enum Reasons {
    /// The headline of a status whose healthy (or unknown) report has gone old.
    static let oldHeadline = "Can’t tell · last report is old"

    /// The headline of a problem report that has gone old: still shown, never as current.
    static func lastReported(_ headline: String) -> String { "Last reported: \(headline) · old" }

    /// The summary's form of an old problem: "Paused, old report".
    static func briefOld(_ headline: String) -> String { "\(headline) (old report)" }

    /// A report dated later than this Mac's clock.
    static let futureHeadline = "Can’t tell"
    static func future(_ report: ProviderReport) -> String {
        "The last \(report.label) is dated \(RelTime.clock(report.written)), later than this Mac’s clock. Velum waits for the next one."
    }

    /// The tracker isn't watching this account's folders yet (just after launch, or a new account).
    static let notWatchingYet = "Velum has just started watching this account and can’t vouch for it yet."

    /// Added to a "can't tell" reason when Velum's own tracking is complete and nothing is pending.
    static let nothingWaiting = "Nothing is waiting to upload."

    /// Used when a provider gives no wording of its own for an old report.
    static func old(_ report: ProviderReport, now: Date) -> String {
        "The last \(report.label) is \(duration(now.timeIntervalSince(report.written))) old."
    }

    /// The client's own status text in words Velum doesn't recognize (another language, a new message).
    static func unrecognizedWords(_ provider: ProviderID) -> String {
        "Velum doesn’t recognize \(provider.name)’s words here."
    }

    /// FSEvents dropped events, or Velum was off too long to replay them, so "nothing pending" isn't proof.
    /// It says what ends the gap: the tracker's re-check of the account's folders, never a timer. While the
    /// re-check runs it promises no time, because how long it takes depends on how many files there are.
    /// A first look (folders no re-check has walked yet) says so instead: Velum didn't miss anything there.
    static func coverageGap(since: Date?, check: CoverageCheck?, firstLook: Bool = false) -> String {
        if firstLook {
            if case .failed(let why, let retry) = check {
                return "Velum couldn’t look through these folders yet: \(recheckFailure(why)). It tries again at \(RelTime.clock(retry))."
            }
            return "Velum is looking through these folders for the first time before it vouches for them."
        }
        let missed = "Velum may have missed changes here" + (since.map { " around \(RelTime.clock($0))" } ?? "")
        switch check {
        case .failed(let why, let retry):
            return "\(missed) and couldn’t re-check these folders: \(recheckFailure(why)). It tries again at \(RelTime.clock(retry))."
        case .checking, nil:
            return "\(missed), so it’s re-checking these folders before it vouches for them again."
        }
    }

    /// Why a re-check couldn't finish, as the end of a sentence (the reason line and the debug log).
    static func recheckFailure(_ why: RecheckFailure) -> String {
        switch why {
        case .tooManyFiles(let limit): "they hold more than \(limit.formatted()) files"
        case .tooManyPending(let limit): "more than \(limit.formatted()) files are waiting to upload"
        case .unreadable: "a folder couldn’t be read"
        }
    }

    /// The summary's line for accounts Velum can't tell about: "Can't tell for Personal", "… for Personal or
    /// iCloud Drive", "… for 3 of 4 accounts".
    static func cantTell(_ names: [String], of total: Int) -> String? {
        switch names.count {
        case 0: nil
        case 1: "Can’t tell for \(names[0])"
        case 2: "Can’t tell for \(names[0]) or \(names[1])"
        default: "Can’t tell for \(names.count) of \(total) accounts"
        }
    }

    /// For VoiceOver: "12 min ago" → "12 minutes ago", "1 hr ago" → "1 hour ago".
    static func spoken(_ text: String) -> String {
        var s = text
        for (short, one, many) in [("min", "minute", "minutes"), ("hr", "hour", "hours")] {
            s = s.replacingOccurrences(of: "\\b1 \(short) ago", with: "1 \(one) ago", options: .regularExpression)
            s = s.replacingOccurrences(of: "\\b(\\d+) \(short) ago", with: "$1 \(many) ago", options: .regularExpression)
        }
        return s
    }

    /// "40 minutes", "1 hour", "3 hours", "2 days": how old something is, in words for a sentence.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = minutes / 60
        if hours < 24 { return hours == 1 ? "1 hour" : "\(hours) hours" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}
