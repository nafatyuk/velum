import Foundation
import Testing
@testable import Velum

@Suite struct LidVerdicts {
    func account(_ config: AccountConfig, pending: Int = 0, failed: Int = 0, covered: Bool = true,
                 running: Bool = true) -> AccountStatus {
        var uploads = UploadSummary()
        uploads.waiting = pending
        uploads.failed = Array(repeating: "x: y", count: failed)
        uploads.coverageGap = !covered
        return Fixture.status(Fixture.evidence(config, running: running, report: Fixture.report(.ok, "Up to date")),
                              uploads: uploads)
    }

    func snapshot(_ accounts: [AccountStatus], providers: [ProviderStatus]) -> Snapshot {
        var s = Snapshot()
        s.accounts = accounts
        s.providers = providers
        return s
    }

    let oneDriveRunning = ProviderStatus(id: .oneDrive, clientRunning: true)
    let iCloudOn = ProviderStatus(id: .iCloud, clientRunning: nil)

    @Test func safeAcrossProviders() {
        let s = snapshot([account(Fixture.oneDrive()), account(Fixture.iCloud())], providers: [oneDriveRunning, iCloudOn])
        #expect(s.lidVerdict == .safe)
    }

    @Test func iCloudPendingMakesYouWait() {
        let s = snapshot([account(Fixture.oneDrive()), account(Fixture.iCloud(), pending: 3)], providers: [oneDriveRunning, iCloudOn])
        #expect(s.lidVerdict == .pending(3))
    }

    @Test func failuresOutrankPending() {
        let s = snapshot([account(Fixture.oneDrive(), failed: 1), account(Fixture.iCloud(), pending: 3)],
                         providers: [oneDriveRunning, iCloudOn])
        #expect(s.lidVerdict == .failing(1))
    }

    @Test func stoppedClientNamesItself() {
        let stopped = ProviderStatus(id: .oneDrive, clientRunning: false)
        let s = snapshot([account(Fixture.oneDrive(), running: false), account(Fixture.iCloud())], providers: [stopped, iCloudOn])
        #expect(s.lidVerdict == .notRunning("OneDrive"))
        #expect(s.stoppedProviders == [.oneDrive])
    }

    @Test func aGapAnywhereMeansCantVouch() {
        let s = snapshot([account(Fixture.oneDrive()), account(Fixture.iCloud(), covered: false)], providers: [oneDriveRunning, iCloudOn])
        #expect(s.lidVerdict == .unknown("Velum may have missed recent changes in iCloud Drive"))
    }

    @Test func noAccountsKeepsTheOldWording() {
        #expect(snapshot([], providers: [oneDriveRunning]).lidVerdict == .unknown("No OneDrive accounts found"))
        #expect(snapshot([], providers: []).lidVerdict == .unknown("No cloud accounts found"))
    }
}

@Suite struct ICloudParsing {
    @Test func healthyStatus() {
        let line = "1 containers matching 'com.apple.CloudDocs'\n<c{1}m.a{3}e.C{7}s[1] \u{1B}[0;1;32mforeground\u{1B}[0m {client:idle server:full-sync|fetched-recents sync:oob-sync-ack last-sync:2026-11-11 22:16:31.270, requestID:7, caught-up, token:x}>\n\nDesktop & Documents: current=YES"
        let report = ICloudProvider.parseStatus(line, at: Fixture.now)
        #expect(report?.state == .ok)
        #expect(report?.headline == "Up to date")
        #expect(report?.label == "iCloud status")
    }

    @Test func anythingElseIsUnknown() {
        let busy = "<c{1}m.a{3}e.C{7}s[1] foreground {client:needs-sync server:idle sync:idle last-sync:never}>"
        #expect(ICloudProvider.parseStatus(busy, at: Fixture.now)?.state == .unknown)
        #expect(ICloudProvider.parseStatus("", at: Fixture.now) == nil)
        #expect(ICloudProvider.parseStatus("garbage\nmore garbage", at: Fixture.now) == nil)
    }

    @Test func quota() {
        #expect(ICloudProvider.parseQuota("1272173412087 bytes of quota remaining in personal account\n") == 1_272_173_412_087)
        #expect(ICloudProvider.parseQuota("0 bytes of quota remaining in personal account") == 0)
        #expect(ICloudProvider.parseQuota("error: not signed in") == nil)
    }

    @Test func discoveryFindsNothingWithoutICloudDrive() {
        let empty = FileManager.default.temporaryDirectory.appending(path: "velum-test-\(UUID().uuidString)")
        #expect(ICloudProvider(home: empty).discover() == nil)
    }
}

@Suite struct Tracking {
    @Test func namesNeverUploaded() {
        #expect(!UploadTracker.isSyncable("/x/.DS_Store"))
        #expect(!UploadTracker.isSyncable("/x/~$Essay.docx"))
        #expect(!UploadTracker.isSyncable("/x/._Essay.docx"))
        #expect(!UploadTracker.isSyncable("/x/a.fetch"))
        #expect(UploadTracker.isSyncable("/x/Essay.docx"))
    }

    @Test func iCloudsBusyErrorIsWaiting() {
        let busy = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileUbiquityServerNotAvailable)
        let full = NSError(domain: NSCocoaErrorDomain, code: NSUbiquitousFileNotUploadedDueToQuotaError)
        #expect(UploadTracker.isTransient(busy))
        #expect(!UploadTracker.isTransient(full))
    }
}

@Suite struct Locations {
    @Test func oneDriveWordingUnchanged() {
        let c = Fixture.oneDrive()
        #expect(c.location(of: c.folder.path + "/a.docx") == "In the top of OneDrive-Personal")
        #expect(c.location(of: c.folder.path + "/Classes/Week 1/a.docx") == "In Classes/Week 1")
        #expect(c.location(of: "/Users/test/OneDrive/Taxes/a.pdf") == "In Taxes")
        #expect(c.location(of: "/elsewhere/a.pdf") == nil)
    }

    @Test func iCloudNamesDesktopAndDocuments() {
        let c = Fixture.iCloud()
        #expect(c.location(of: c.folder.path + "/a.pages") == "In the top of iCloud Drive")
        #expect(c.location(of: "/Users/test/Desktop/Screenshot.png") == "In Desktop")
        #expect(c.location(of: "/Users/test/Documents/Taxes/2026/a.pdf") == "In Documents/Taxes/2026")
        #expect(c.location(of: "/Users/test/Downloads/a.pdf") == nil)
    }
}

@MainActor
@Suite struct Alerts {
    func snapshot(oneDriveRunning: Bool, iCloudPending: Int = 0, since: Date? = nil) -> Snapshot {
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .oneDrive, clientRunning: oneDriveRunning), ProviderStatus(id: .iCloud)]
        var uploads = UploadSummary()
        uploads.waiting = iCloudPending
        uploads.oldestWaiting = since
        s.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), running: oneDriveRunning)),
                      Fixture.status(Fixture.evidence(Fixture.iCloud()), uploads: uploads)]
        return s
    }

    @Test func stoppedClientAlertsOnceThenResolves() {
        let notifier = Notifier()
        var shown: [(String, String)] = []
        notifier.fallback = { title, body, _ in shown.append((title, body)) }
        let t0 = Fixture.now
        notifier.update(snapshot(oneDriveRunning: false), enabled: true, now: t0)
        #expect(shown.isEmpty)                                   // settles for 30 s first
        notifier.update(snapshot(oneDriveRunning: false), enabled: true, now: t0.addingTimeInterval(31))
        notifier.update(snapshot(oneDriveRunning: false), enabled: true, now: t0.addingTimeInterval(60))
        #expect(shown.map(\.0) == ["OneDrive stopped"])           // once, and no per-account echo
        notifier.update(snapshot(oneDriveRunning: true), enabled: true, now: t0.addingTimeInterval(90))
        #expect(shown.last?.0 == "OneDrive: resolved")
        #expect(shown.last?.1 == "OneDrive is running again.")
    }

    @Test func quittingFromVelumIsNotAProblem() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        let t0 = Fixture.now
        notifier.userStopped[.oneDrive] = t0
        notifier.update(snapshot(oneDriveRunning: false), enabled: true, now: t0)
        notifier.update(snapshot(oneDriveRunning: false), enabled: true, now: t0.addingTimeInterval(40))
        #expect(shown.isEmpty)
    }

    @Test func stuckICloudUploadsAlert() {
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        let t0 = Fixture.now
        let since = t0.addingTimeInterval(-11 * 60)
        notifier.update(snapshot(oneDriveRunning: true, iCloudPending: 2, since: since), enabled: true, now: t0)
        notifier.update(snapshot(oneDriveRunning: true, iCloudPending: 2, since: since), enabled: true, now: t0.addingTimeInterval(31))
        #expect(shown == ["iCloud Drive: uploads are stuck"])
    }
}
