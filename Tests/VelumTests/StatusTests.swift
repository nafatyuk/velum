import Foundation
import Testing
@testable import Velum

/// The status merge's order and wording, the same for every provider. These pin what the panel said
/// before providers existed, so OneDrive's rows must not change.
@Suite struct StatusOrder {
    let personal = Fixture.oneDrive()

    @Test func notRunningComesFirst() {
        let s = Fixture.status(Fixture.evidence(personal, running: false, exact: "Up to date",
                                                report: Fixture.report(.ok, "Up to date")))
        #expect(s.state == .notRunning)
        #expect(s.headline == "Not running, so nothing is syncing")
        #expect(s.uploadsCovered == false)
    }

    @Test func exactStatusWinsAndNamesTheProvider() {
        var uploads = UploadSummary()
        uploads.failed = ["a.docx: nope"]
        let s = Fixture.status(Fixture.evidence(personal, exact: "Backed up and synced"), uploads: uploads)
        #expect(s.state == .ok)
        #expect(s.headline == "Backed up and synced")
        #expect(s.source == "From OneDrive")
        #expect(s.isLive)
    }

    @Test func emptyExactStatusIsFoundButNotUsed() {
        let s = Fixture.status(Fixture.evidence(personal, exact: "", report: Fixture.report(.ok, "Up to date")))
        #expect(s.isLive)
        #expect(s.source.hasPrefix("Nothing pending · OneDrive report, "))
    }

    @Test func failuresBeforeMovement() {
        var uploads = UploadSummary()
        uploads.failed = ["Thesis.docx: Name too long", "b.txt: x"]
        uploads.uploading = 3
        let s = Fixture.status(Fixture.evidence(personal), uploads: uploads)
        #expect(s.state == .error)
        #expect(s.headline == "2 files can't upload")
        #expect(s.detail == "Thesis.docx: Name too long · Live from macOS")
        #expect(s.uploadsFailed == 2)
    }

    @Test func movingFiles() {
        var transfer = TransferInfo()
        transfer.downloadingFiles = 2
        var uploads = UploadSummary()
        uploads.uploading = 1
        #expect(Fixture.status(Fixture.evidence(personal), transfer: transfer, uploads: uploads).headline == "Syncing 3 files")
        #expect(Fixture.status(Fixture.evidence(personal), uploads: uploads).headline == "Uploading 1 file")
        #expect(Fixture.status(Fixture.evidence(personal), transfer: transfer).headline == "Downloading 2 files")
    }

    @Test func waitingAndPaused() {
        var uploads = UploadSummary()
        uploads.waiting = 2
        uploads.oldestWaiting = Fixture.now.addingTimeInterval(-20 * 60)
        let waiting = Fixture.status(Fixture.evidence(personal), uploads: uploads)
        #expect(waiting.state == .syncing)
        #expect(waiting.headline == "Waiting to upload 2 files")
        #expect(waiting.detail.hasPrefix("waiting since "))
        #expect(waiting.uploadsPending == 2)
        let paused = Fixture.status(Fixture.evidence(personal, report: Fixture.report(.paused, "Paused")), uploads: uploads)
        #expect(paused.state == .paused)
        #expect(paused.headline == "Paused, 2 files waiting")
    }

    @Test func unlabelledProgress() {
        var transfer = TransferInfo()
        transfer.otherFiles = 2
        let s = Fixture.status(Fixture.evidence(personal), transfer: transfer)
        #expect(s.headline == "Syncing changes")
    }

    @Test func healthyReportNeedsCoverageToSayNothingPending() {
        let covered = Fixture.status(Fixture.evidence(personal, report: Fixture.report(.ok, "Up to date")))
        #expect(covered.state == .ok)
        #expect(covered.source.hasPrefix("Nothing pending · OneDrive report, "))
        var gap = UploadSummary()
        gap.coverageGap = true
        let blind = Fixture.status(Fixture.evidence(personal, report: Fixture.report(.ok, "Up to date")), uploads: gap)
        #expect(blind.state == .ok)
        #expect(blind.source.hasPrefix("OneDrive report, "))
        #expect(blind.uploadsCovered == false)
    }

    @Test func noEvidenceIsNeverUpToDate() {
        let s = Fixture.status(Fixture.evidence(personal))
        #expect(s.state == .unknown)
        #expect(s.headline == "No status yet")
    }

    @Test func iCloudNotesGoOnTheirOwnLine() {
        var e = Fixture.evidence(Fixture.iCloud(), report: Fixture.report(.ok, "Up to date", label: "iCloud status"))
        e.notes = ["Desktop & Documents included", "1.27 TB free"]
        let s = Fixture.status(e)
        #expect(s.notes == "Desktop & Documents included · 1.27 TB free")
        #expect(s.source.hasPrefix("Nothing pending · iCloud status, "))
        #expect(!s.detail.contains("free"))
    }
}

@Suite struct OneDriveReports {
    func diag(_ code: Int?) -> Diagnostics {
        var d = Diagnostics(written: Fixture.now)
        d.progressState = code
        return d
    }

    @Test(arguments: [(65536, SyncState.paused, "Paused"), (8194, .offline, "Not syncing"), (1854, .error, "Sync issue"),
                      (0, .ok, "Up to date"), (16777216, .ok, "Up to date"), (42, .unknown, "Status unknown")])
    func codes(code: Int, state: SyncState, headline: String) {
        let report = OneDriveProvider.report(from: diag(code))
        #expect(report?.state == state)
        #expect(report?.headline == headline)
        #expect(report?.label == "OneDrive report")
    }

    @Test func noCodeNoReport() {
        #expect(OneDriveProvider.report(from: diag(nil)) == nil)
        #expect(OneDriveProvider.report(from: nil) == nil)
    }

    @Test func classifiesOneDriveWording() {
        #expect(SyncState.classify("Backed up and synced") == .ok)
        #expect(SyncState.classify("Syncing 3 files") == .syncing)
        #expect(SyncState.classify("Paused") == .paused)
        #expect(SyncState.classify("Your OneDrive is full") == .error)
        #expect(SyncState.classify("Synchronisation läuft") == .unknown)
    }
}
