import Foundation
import Testing
@testable import Velum

// A4: what each light means, why a row can't tell, and how old its evidence is. All evidence is made up.

private let hour: TimeInterval = 3600
private let minute: TimeInterval = 60

private func oneDriveReport(_ state: SyncState, _ headline: String, ago: TimeInterval, code: Int = 0) -> ProviderReport {
    var r = ProviderReport(label: "OneDrive report", written: Fixture.now.addingTimeInterval(-ago), state: state,
                           headline: headline, every: OneDriveProvider.reportEvery)
    r.reason = OneDriveProvider.reason(for: r, code: code, now: Fixture.now)
    return r
}

private func clock(_ offset: TimeInterval) -> String { RelTime.clock(Fixture.now.addingTimeInterval(offset)) }

@Suite struct OldEvidence {
    let personal = Fixture.oneDrive()

    @Test func thresholdIsTheIntervalPlusFifteenMinutes() {
        let at = { (ago: TimeInterval, every: TimeInterval) in
            ProviderReport(label: "x", written: Fixture.now.addingTimeInterval(-ago), state: .ok, headline: "Up to date",
                           every: every).isOld(now: Fixture.now)
        }
        #expect(!at(75 * minute, OneDriveProvider.reportEvery))
        #expect(at(75 * minute + 1, OneDriveProvider.reportEvery))
        #expect(!at(25 * minute, ICloudProvider.checkInterval))
        #expect(at(25 * minute + 1, ICloudProvider.checkInterval))
        // Live evidence has no age to go old, and a report with no schedule can't be judged.
        let live = ProviderReport(label: "x", written: Fixture.now.addingTimeInterval(-10 * hour), state: .ok,
                                  headline: "Up to date", timed: false, every: hour)
        #expect(!live.isOld(now: Fixture.now))
        #expect(!ProviderReport(label: "x", written: .distantPast, state: .ok, headline: "Up to date").isOld(now: Fixture.now))
    }

    @Test func freshHealthyReportIsGreenWithItsAge() {
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 74 * minute)))
        #expect(s.state == .ok)
        #expect(s.age == "1 hr ago")
        #expect(!s.isOld)
        #expect(s.reason == nil)
        #expect(s.detail == "Nothing pending · OneDrive report 1 hr ago")
    }

    @Test func oldHealthyReportIsNeverGreen() {
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 3 * hour)))
        #expect(s.state == .unknown)
        #expect(s.isOld)
        #expect(s.headline == "Can’t tell · last report is old")
        #expect(s.reason == "OneDrive last reported “Up to date” at \(clock(-3 * hour)), 3 hours ago. It reports about hourly while it runs and this Mac is awake, less often when nothing changes. Nothing is waiting to upload.")
        // The reason names the source and its time, so the source line goes; "Nothing pending" isn't claimed.
        #expect(s.detail.isEmpty)
        #expect(!s.source.hasPrefix("Nothing pending"))
    }

    @Test func oldProblemStaysAProblemMarkedOld() {
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.paused, "Paused", ago: 2 * hour, code: 65536)))
        #expect(s.state == .paused)
        #expect(s.headline == "Last reported: Paused · old")
        #expect(s.briefHeadline == "Paused (old report)")
        #expect(s.reason == "This report is 2 hours old. OneDrive may have changed since.")
        #expect(s.detail == "OneDrive report 2 hr ago")
        let issue = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.error, "Sync issue", ago: 2 * hour, code: 1854)))
        #expect(issue.state == .error)
        #expect(issue.headline == "Last reported: Sync issue · old")
    }

    @Test func oldUnknownCodeSaysOld() {
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.unknown, "Can’t tell", ago: 2 * hour, code: 42)))
        #expect(s.headline == "Can’t tell · last report is old")
        #expect(s.reason?.hasPrefix("OneDrive’s last report, at \(clock(-2 * hour)), is 2 hours old.") == true)
    }

    @Test func reportFromTheFutureIsNotTrusted() {
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: -2 * hour)))
        #expect(s.state == .unknown)
        #expect(s.headline == "Can’t tell")
        #expect(s.age.isEmpty)
        #expect(s.reason == "The last OneDrive report is dated \(clock(2 * hour)), later than this Mac’s clock. Velum waits for the next one. Nothing is waiting to upload.")
        // A future pause can't relabel waiting files either; a few minutes' skew is tolerated.
        var uploads = UploadSummary()
        uploads.waiting = 1
        #expect(Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.paused, "Paused", ago: -2 * hour)),
                               uploads: uploads).headline == "Waiting to upload 1 file")
        #expect(Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: -4 * minute))).state == .ok)
    }

    @Test func oldPauseDoesNotRelabelWaitingFiles() {
        var uploads = UploadSummary()
        uploads.waiting = 2
        let old = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.paused, "Paused", ago: 3 * hour)), uploads: uploads)
        #expect(old.state == .syncing)
        #expect(old.headline == "Waiting to upload 2 files")
        let fresh = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.paused, "Paused", ago: 10 * minute)), uploads: uploads)
        #expect(fresh.headline == "Paused, 2 files waiting")
    }

    @Test func periodicReportsNeverHoldTheLid() {
        for ago in [3 * hour, 5 * minute] {
            let report = ProviderReport(label: "Some queue", written: Fixture.now.addingTimeInterval(-ago), state: .syncing,
                                        headline: "Syncing changes", every: hour)
            #expect(!Fixture.status(Fixture.evidence(personal, report: report)).workPending)
        }
        // Live evidence (Google Drive's queue) still may.
        let live = ProviderReport(label: "Google Drive's queue", written: Fixture.now, state: .syncing, headline: "Syncing changes", timed: false)
        #expect(Fixture.status(Fixture.evidence(personal, report: live)).workPending)
    }

    @Test func everyOldReportIsNeverGreen() {
        for state in [SyncState.ok, .unknown, .syncing, .offline, .paused, .warning, .error] {
            let report = ProviderReport(label: "r", written: Fixture.now.addingTimeInterval(-5 * hour), state: state,
                                        headline: "h", every: hour)
            #expect(Fixture.status(Fixture.evidence(personal, report: report)).state != .ok)
        }
    }
}

/// An old report must never make "Safe to close the lid" true: the lid line reads live tracking only.
@Suite struct OldEvidenceAndTheLid {
    let providers = [ProviderStatus(id: .oneDrive, clientRunning: true)]

    func lid(_ report: ProviderReport?, uploads: UploadSummary?, watching: Bool) -> LidVerdict {
        var s = Snapshot()
        s.providers = providers
        s.accounts = [Collector.status(Fixture.evidence(Fixture.oneDrive(), report: report), transfer: nil, uploads: uploads,
                                       watchingUploads: watching, now: Fixture.now)]
        return s.lidVerdict
    }

    @Test func oldHealthyReportNeverMakesItSafe() {
        let old = oneDriveReport(.ok, "Up to date", ago: 4 * hour)
        var gap = UploadSummary()
        gap.coverageGap = true
        #expect(lid(old, uploads: gap, watching: true) != .safe)
        #expect(lid(old, uploads: nil, watching: false) != .safe)
        // And it changes nothing when live tracking does decide: same verdict as no report at all.
        #expect(lid(old, uploads: UploadSummary(), watching: true) == lid(nil, uploads: UploadSummary(), watching: true))
        #expect(lid(old, uploads: gap, watching: true) == lid(nil, uploads: gap, watching: true))
    }

    @Test func oldSyncingReportDoesNotHoldTheLid() {
        let old = ProviderReport(label: "Some queue", written: Fixture.now.addingTimeInterval(-3 * hour), state: .syncing,
                                 headline: "Syncing changes", every: hour)
        #expect(lid(old, uploads: UploadSummary(), watching: true) == .safe)   // live tracking: nothing pending
    }
}

@Suite struct ReasonTexts {
    let personal = Fixture.oneDrive()

    @Test func oneDriveNoReportYetThenOverdue() {
        let since = Fixture.now.addingTimeInterval(-20 * minute)
        #expect(OneDriveProvider.noReportReason(diag: nil, since: since, now: Fixture.now)
                == "No OneDrive report yet. OneDrive usually writes one about every hour while it runs and this Mac is awake.")
        // An hour after Velum started looking, the line says so.
        let due = since.addingTimeInterval(hour)
        #expect(OneDriveProvider.noReportReason(diag: nil, since: since, now: due).hasPrefix("No OneDrive report yet."))
        #expect(OneDriveProvider.noReportReason(diag: nil, since: since, now: due.addingTimeInterval(1))
                == "No OneDrive report since \(clock(-20 * minute)), though it writes one about every hour while this Mac is awake.")
    }

    @Test func oneDriveReportWithoutAStatus() {
        let diag = Diagnostics(written: Fixture.now.addingTimeInterval(-5 * minute))
        #expect(OneDriveProvider.noReportReason(diag: diag, since: Fixture.now, now: Fixture.now)
                == "OneDrive’s report at \(clock(-5 * minute)) had no status Velum can read. Velum keeps looking.")
    }

    @Test func oneDriveUnknownCode() {
        var diag = Diagnostics(written: Fixture.now.addingTimeInterval(-10 * minute))
        diag.progressState = 4097
        let report = OneDriveProvider.report(from: diag, now: Fixture.now)
        #expect(report?.state == .unknown)
        #expect(report?.reason == "OneDrive reported a status Velum doesn’t recognize (code 4097). Its next report is due by \(clock(50 * minute)).")
        let s = Fixture.status(Fixture.evidence(personal, report: report))
        #expect(s.headline == "Can’t tell")
        #expect(s.reason?.hasPrefix("OneDrive reported a status") == true)
        #expect(s.age == "10 min ago")
        // Once the next report is due and hasn't come, the promise turns into "overdue".
        diag.written = Fixture.now.addingTimeInterval(-65 * minute)
        #expect(OneDriveProvider.report(from: diag, now: Fixture.now)?.reason
                == "OneDrive reported a status Velum doesn’t recognize (code 4097). Its next report is overdue.")
    }

    @Test func freshKnownReportsHaveNoReason() {
        for (code, state) in [(0, SyncState.ok), (65536, .paused), (1854, .error)] {
            var diag = Diagnostics(written: Fixture.now.addingTimeInterval(-10 * minute))
            diag.progressState = code
            let report = OneDriveProvider.report(from: diag, now: Fixture.now)
            #expect(report?.state == state)
            #expect(report?.reason == nil)
            #expect(report?.every == OneDriveProvider.reportEvery)
        }
    }

    @Test func oneDriveWordsVelumDoesNotKnow() {
        let s = Fixture.status(Fixture.evidence(personal, exact: "Synchronisation en pause prolongée"))
        #expect(s.state == .unknown)
        #expect(s.headline == "Synchronisation en pause prolongée")
        #expect(s.reason == "Velum doesn’t recognize OneDrive’s words here.")
        #expect(s.age == "live")
        #expect(s.detail == "From OneDrive, live")
    }

    @Test func iCloudBeforeAndAfterChecks() {
        let last = Fixture.now.addingTimeInterval(-3 * minute)
        let next = last.addingTimeInterval(ICloudProvider.checkInterval)
        #expect(ICloudProvider.noStatusReason(lastCheck: nil, answered: nil, checking: true, next: nil)
                == "Checking iCloud now. This takes about 15 seconds.")
        #expect(ICloudProvider.noStatusReason(lastCheck: last, answered: false, checking: false, next: next)
                == "iCloud didn’t answer the \(clock(-3 * minute)) check. Velum tries again at \(clock(7 * minute)).")
        #expect(ICloudProvider.noStatusReason(lastCheck: last, answered: false, checking: true, next: next)
                == "iCloud didn’t answer the \(clock(-3 * minute)) check. Velum is asking again now.")
    }

    @Test func iCloudNotCaughtUpAndOld() {
        let busy = "<c{1}m.a{3}e.C{7}s[1] foreground {client:needs-sync server:idle sync:idle last-sync:never}>"
        let report = ICloudProvider.parseStatus(busy, at: Fixture.now.addingTimeInterval(-3 * minute))!
        #expect(report.headline == "Can’t tell")
        #expect(report.every == ICloudProvider.checkInterval)
        let next = Fixture.now.addingTimeInterval(7 * minute)
        #expect(ICloudProvider.reason(for: report, answered: true, checking: false, next: next, now: Fixture.now)
                == "At \(clock(-3 * minute)) iCloud didn’t say it’s caught up. Velum checks again at \(clock(7 * minute)).")
        #expect(ICloudProvider.reason(for: report, answered: true, checking: true, next: next, now: Fixture.now)
                == "At \(clock(-3 * minute)) iCloud didn’t say it’s caught up. Velum is checking again now.")

        let healthy = ProviderReport(label: "iCloud status", written: Fixture.now.addingTimeInterval(-40 * minute), state: .ok,
                                     headline: "Up to date", every: ICloudProvider.checkInterval)
        #expect(ICloudProvider.reason(for: healthy, answered: false, checking: false, next: next, now: Fixture.now)
                == "iCloud’s last answer, at \(clock(-40 * minute)), is 40 minutes old; it hasn’t answered since. Velum checks again at \(clock(7 * minute)).")
        // After sleep no check may have run, so it doesn't claim iCloud failed to answer.
        #expect(ICloudProvider.reason(for: healthy, answered: true, checking: true, next: next, now: Fixture.now)
                == "iCloud’s last answer, at \(clock(-40 * minute)), is 40 minutes old. Velum is checking again now.")
        let fresh = ProviderReport(label: "iCloud status", written: Fixture.now.addingTimeInterval(-4 * minute), state: .ok,
                                   headline: "Up to date", every: ICloudProvider.checkInterval)
        #expect(ICloudProvider.reason(for: fresh, answered: true, checking: false, next: next, now: Fixture.now) == nil)
    }

    @Test func coverageGap() {
        let since = Fixture.now.addingTimeInterval(-6 * minute)
        // It says what ends the gap: the re-check, not a time (how long it takes depends on the files).
        #expect(Reasons.coverageGap(since: since, check: .checking)
                == "Velum may have missed changes here around \(clock(-6 * minute)), so it’s re-checking these folders before it vouches for them again.")
        #expect(Reasons.coverageGap(since: nil, check: nil)
                == "Velum may have missed changes here, so it’s re-checking these folders before it vouches for them again.")
        // A re-check that couldn't finish says why, and when it runs again.
        let retry = Fixture.now.addingTimeInterval(30 * minute)
        #expect(Reasons.coverageGap(since: since, check: .failed(.tooManyFiles(100_000), retry: retry))
                == "Velum may have missed changes here around \(clock(-6 * minute)) and couldn’t re-check these folders: they hold more than \(100_000.formatted()) files. It tries again at \(clock(30 * minute)).")
        #expect(Reasons.coverageGap(since: since, check: .failed(.unreadable, retry: retry))
                == "Velum may have missed changes here around \(clock(-6 * minute)) and couldn’t re-check these folders: a folder couldn’t be read. It tries again at \(clock(30 * minute)).")
        #expect(Reasons.recheckFailure(.tooManyPending(5000)) == "more than \(5000.formatted()) files are waiting to upload")
        // A gap under a green row explains the lid line; the row keeps its source and age.
        var gap = UploadSummary()
        gap.coverageGap = true
        gap.coverageGapSince = since
        gap.coverageCheck = .checking
        let s = Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 10 * minute)), uploads: gap)
        #expect(s.state == .ok)
        #expect(s.reason == Reasons.coverageGap(since: since, check: .checking))
        #expect(s.detail == "OneDrive report 10 min ago")
    }

    @Test func nothingWaitingOnlyWhenTrackingIsComplete() {
        var e = Fixture.evidence(personal)
        e.unknownReason = "No report."
        #expect(Fixture.status(e).reason == "No report. Nothing is waiting to upload.")
        #expect(Fixture.status(e, uploads: nil, watching: false).reason
                == "No report. Velum has just started watching this account and can’t vouch for it yet.")
        var gap = UploadSummary()
        gap.coverageGap = true
        #expect(Fixture.status(e, uploads: gap).reason
                == "No report. Velum may have missed changes here, so it’s re-checking these folders before it vouches for them again.")
        var failed = UploadSummary()
        failed.failed = ["a.txt: nope"]
        #expect(Fixture.status(e, uploads: failed).reason == nil)   // the failure itself is the status
    }

    @Test func notRunningNeedsNoReason() {
        var e = Fixture.evidence(personal, running: false)
        e.unknownReason = "No report."
        let s = Fixture.status(e)
        #expect(s.state == .notRunning)
        #expect(s.reason == nil)   // "Not running" is itself the answer
    }
}

@Suite struct AgeWording {
    let personal = Fixture.oneDrive()

    @Test func liveSourcesSayLive() {
        #expect(Fixture.status(Fixture.evidence(personal, exact: "Up to date")).detail == "From OneDrive, live")
        var uploads = UploadSummary()
        uploads.uploading = 1
        let moving = Fixture.status(Fixture.evidence(personal), uploads: uploads)
        #expect(moving.age == "live")
        #expect(moving.detail == "Live from macOS")
        let google = GoogleDriveProvider.config(email: "a@b.c", root: URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c"))
        let queue = Fixture.status(Fixture.evidence(google, report: GoogleDriveProvider.report(queued: 0, now: Fixture.now)))
        #expect(queue.age == "live")
        #expect(queue.detail == "Nothing pending · Google Drive's queue, live")
    }

    @Test func reportsSayHowOld() {
        #expect(Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 30))).age == "just now")
        #expect(Fixture.status(Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 12 * minute))).age == "12 min ago")
        var e = Fixture.evidence(personal, report: oneDriveReport(.ok, "Up to date", ago: 12 * minute))
        e.lastActivity = Fixture.now.addingTimeInterval(-5 * minute)
        #expect(Fixture.status(e).detail == "Nothing pending · OneDrive report 12 min ago · last change 5 min ago")
    }

    @Test func noEvidenceHasNoAge() {
        #expect(Fixture.status(Fixture.evidence(personal)).age.isEmpty)
    }

    @Test func durationsInWords() {
        #expect(Reasons.duration(60) == "1 minute")
        #expect(Reasons.duration(40 * minute) == "40 minutes")
        #expect(Reasons.duration(hour) == "1 hour")
        #expect(Reasons.duration(3 * hour + 59 * minute) == "3 hours")
        #expect(Reasons.duration(26 * hour) == "1 day")
        #expect(Reasons.duration(50 * hour) == "2 days")
    }

    @Test func voiceOverSpellsUnitsOut() {
        #expect(Reasons.spoken("OneDrive report 12 min ago · last change 1 min ago")
                == "OneDrive report 12 minutes ago · last change 1 minute ago")
        #expect(Reasons.spoken("iCloud status 1 hr ago, then 21 min ago and 3 hr ago")
                == "iCloud status 1 hour ago, then 21 minutes ago and 3 hours ago")
    }
}

@MainActor @Suite struct CantTellSummary {
    func summary(_ accounts: [AccountStatus]) -> String {
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .oneDrive, clientRunning: true)]
        s.accounts = accounts
        let store = Store()
        store.show(s)
        return store.summary
    }

    func account(_ name: String, _ report: ProviderReport?) -> AccountStatus {
        Fixture.status(Fixture.evidence(Fixture.oneDrive(name, name: name), report: report))
    }

    @Test func unknownIsSaidAndNeverCountedAsAttention() {
        let ok = Fixture.report(.ok, "Up to date")
        let paused = Fixture.report(.paused, "Paused")
        #expect(summary([account("A", ok), account("B", ok)]) == "Both accounts are up to date")
        #expect(summary([account("A", ok), account("B", nil)]) == "Can’t tell for B")
        #expect(summary([account("A", nil), account("B", nil)]) == "Can’t tell for A or B")
        #expect(summary([account("A", nil), account("B", nil), account("C", nil), account("D", ok)]) == "Can’t tell for 3 of 4 accounts")
        #expect(summary([account("A", paused), account("B", nil)]) == "A: Paused · Can’t tell for B")
        let oldPause = ProviderReport(label: "OneDrive report", written: Fixture.now.addingTimeInterval(-3 * hour), state: .paused,
                                      headline: "Paused", every: OneDriveProvider.reportEvery)
        #expect(summary([account("A", oldPause), account("B", nil)]) == "A: Paused (old report) · Can’t tell for B")
        #expect(summary([account("A", paused), account("B", paused), account("C", paused), account("D", nil)])
                == "3 of 4 accounts need attention · Can’t tell for D")
    }
}

@Suite struct LegendWords {
    @Test func oneLinePerBadge() {
        // Every state has a row except warning, which shares error's "!" badge.
        let badges = Set(LegendView.states.map(\.badge))
        #expect(badges == Set([.ok, .unknown, .syncing, .offline, .paused, .error, .notRunning]))
        #expect(LegendView.states.first?.text == "Nothing needs you. Shown only when Velum has evidence.")
        #expect(LegendView.states.contains { $0.platter == .unknown && $0.text.hasPrefix("Velum can’t tell") })
    }

    @Test func sourcesMatchTheMergesNumbers() {
        let lines = LegendView.sourceLines(for: [.oneDrive, .iCloud, .googleDrive])
        #expect(lines.count == 4)
        #expect(lines[1].hasSuffix("Old after 75 minutes, or 12 hours while nothing is waiting to upload."))
        #expect(lines[2] == "iCloud: a status check Velum runs every 10 minutes. Old after 25 minutes.")
        #expect(lines[3].contains("If Velum can’t read the queue, the row says so."))
        // Only the services on this Mac.
        #expect(LegendView.sourceLines(for: [.iCloud]).count == 2)
    }

    @Test func recentIsPartialForICloudAndGoogleDrive() {
        #expect(LegendView.notesLines(for: [.oneDrive]) == ["Recent: OneDrive’s own history."])
        #expect(LegendView.notesLines(for: [.oneDrive, .iCloud, .googleDrive]).first
                == "Recent: OneDrive’s own history. For iCloud and Google Drive, only uploads Velum saw finish while it was running.")
        #expect(LegendView.notesLines(for: [.iCloud]).first == "Recent: only uploads Velum saw finish while it was running.")
        #expect(LegendView.notesLines(for: [.iCloud]).last == "Storage notes don’t change a row’s light.")
    }

    /// The legend says "almost full: 90% used and under 10 GB free; full: under 100 MB free". Pin the code to it.
    @Test func storageThresholdsMatchTheLegend() {
        let gb: Int64 = 1_073_741_824, mb: Int64 = 1_048_576
        func storage(limit: Int64, used: Int64) -> GoogleStorage {
            GoogleStorage(limit: limit, used: used, usedInDrive: nil, source: .driveCache, asOf: Fixture.now)
        }
        #expect(storage(limit: 100 * gb, used: 91 * gb).isAlmostFull)        // 91 %, 9 GB free
        #expect(storage(limit: 50 * gb, used: 45 * gb).isAlmostFull)        // exactly 90 %, 5 GB free
        #expect(!storage(limit: 100 * gb, used: 89 * gb).isAlmostFull)       // 89 %
        #expect(!storage(limit: 400 * gb, used: 361 * gb).isAlmostFull)      // 90 %, but 39 GB free
        #expect(storage(limit: 100 * gb, used: 100 * gb - 99 * mb).isFull)   // 99 MB free
        #expect(!storage(limit: 100 * gb, used: 100 * gb - 101 * mb).isFull)
        #expect(LegendView.notesLines(for: [.googleDrive]).contains {
            $0.contains("almost full (at least 90% used and under 10 GB free) or full (under 100 MB free)")
        })
    }
}

/// An old problem report is neither news nor resolved (Fable's catch): no alert for it, and an alert already
/// sent gets no false "resolved" when its report merely ages.
@MainActor @Suite struct OldProblemsAndAlerts {
    func snapshot(_ report: ProviderReport) -> Snapshot {
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .oneDrive, clientRunning: true)]
        s.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: report))]
        return s
    }

    @Test func oldSyncIssueNeverAlertsOrResolves() {
        let fresh = oneDriveReport(.error, "Sync issue", ago: 10 * minute, code: 1854)
        let old = oneDriveReport(.error, "Sync issue", ago: 3 * hour, code: 1854)
        let quiet = Notifier()
        var heard: [String] = []
        quiet.fallback = { title, _, _ in heard.append(title) }
        quiet.update(snapshot(old), enabled: true, now: Fixture.now)
        quiet.update(snapshot(old), enabled: true, now: Fixture.now.addingTimeInterval(60))
        #expect(heard.isEmpty)

        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        notifier.update(snapshot(fresh), enabled: true, now: Fixture.now)
        notifier.update(snapshot(fresh), enabled: true, now: Fixture.now.addingTimeInterval(31))
        #expect(shown == ["Personal: Sync issue"])
        notifier.update(snapshot(old), enabled: true, now: Fixture.now.addingTimeInterval(60))
        #expect(shown == ["Personal: Sync issue"])            // aged, not resolved
        notifier.update(snapshot(oneDriveReport(.ok, "Up to date", ago: 1 * minute)), enabled: true,
                        now: Fixture.now.addingTimeInterval(90))
        #expect(shown.last == "Personal: resolved")          // a fresh healthy report does resolve it
    }
}
