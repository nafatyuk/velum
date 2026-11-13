import Foundation
import Testing
@testable import Velum

/// Found live on November 13: a personal OneDrive account wrote no report for 4½ hours while it ran, idle, on
/// an awake Mac. A work account kept to the hour. Velum greyed the quiet account, and with it the menu bar icon,
/// for half the morning. OneDrive's last "Up to date" now counts for up to 12 hours while Velum's live
/// tracking shows nothing waiting. All evidence is made up.
@Suite struct QuietOneDrive {
    let personal = Fixture.oneDrive()
    let hour: TimeInterval = 3600

    func report(_ code: Int, ago: TimeInterval) -> ProviderReport? {
        var d = Diagnostics(written: Fixture.now.addingTimeInterval(-ago))
        d.progressState = code
        return OneDriveProvider.report(from: d, now: Fixture.now)
    }

    func status(_ code: Int = 16777216, ago: TimeInterval, uploads: UploadSummary? = UploadSummary(),
                watching: Bool = true) -> AccountStatus {
        Fixture.status(Fixture.evidence(personal, report: report(code, ago: ago)), uploads: uploads, watching: watching)
    }

    @Test func aQuietAccountStaysUpToDateWithItsTrueAge() {
        let s = status(ago: 4.5 * hour)
        #expect(s.state == .ok)
        #expect(s.headline == "Up to date")
        #expect(!s.isOld)
        #expect(s.reason == nil)
        #expect(s.detail == "Nothing pending · OneDrive report 4 hr ago")
        #expect(s.uploadsCovered)
    }

    @Test func twelveHoursIsTheLimit() {
        #expect(status(ago: 12 * hour).state == .ok)
        let s = status(ago: 12 * hour + 1)
        #expect(s.state == .unknown)
        #expect(s.isOld)
        #expect(s.headline == "Can’t tell · last report is old")
        #expect(s.reason?.contains("It reports about hourly while it runs and this Mac is awake, less often when nothing changes.") == true)
    }

    @Test func onlyWhileVelumWatchesEveryUpload() {
        let notWatching = status(ago: 3 * hour, watching: false)
        #expect(notWatching.state == .unknown)
        #expect(notWatching.isOld)
        var gap = UploadSummary()
        gap.coverageGap = true
        let blind = status(ago: 3 * hour, uploads: gap)
        #expect(blind.state == .unknown)
        #expect(blind.isOld)
        // Before the hour and its grace are up, nothing changes: a fresh report stays green, as before.
        #expect(status(ago: 30 * 60, uploads: gap).state == .ok)
    }

    @Test func pendingWorkStillShowsLiveAndTheReportReturnsAfter() {
        var waiting = UploadSummary()
        waiting.waiting = 1
        waiting.oldestWaiting = Fixture.now.addingTimeInterval(-60)
        let busy = status(ago: 3 * hour, uploads: waiting)
        #expect(busy.state == .syncing)
        #expect(busy.headline == "Waiting to upload 1 file")
        var failing = UploadSummary()
        failing.failed = ["a.docx: nope"]
        #expect(status(ago: 3 * hour, uploads: failing).state == .error)
        // Once it has uploaded, the quiet "Up to date" holds again.
        #expect(status(ago: 3 * hour).state == .ok)
    }

    @Test func onlyAHealthyReportStaysQuiet() {
        let paused = status(65536, ago: 3 * hour)
        #expect(paused.state == .paused)
        #expect(paused.headline == "Last reported: Paused · old")
        #expect(paused.isOld)
        let unknown = status(42, ago: 3 * hour)
        #expect(unknown.headline == "Can’t tell · last report is old")
        #expect(report(16777216, ago: 30 * 60)?.isQuiet(now: Fixture.now) == false)   // fresh: not old, so not quiet
        #expect(report(16777216, ago: 2 * hour)?.isQuiet(now: Fixture.now) == true)
    }

    @Test func iCloudKeepsItsOwnRule() {
        // An old iCloud status means Velum's own check failed, not that iCloud is quiet.
        let line = "<com.apple.CloudDocs[1] foreground {client:idle server:full-sync sync:oob-sync-ack, caught-up}"
        let report = ICloudProvider.parseStatus(line, at: Fixture.now.addingTimeInterval(-2 * hour))
        #expect(report?.state == .ok)
        #expect(report?.quietFor == nil)
        let s = Fixture.status(Fixture.evidence(Fixture.iCloud(), report: report))
        #expect(s.state == .unknown)
        #expect(s.isOld)
    }
}
