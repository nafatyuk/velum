import Foundation
import Testing
@testable import Velum

/// Found live on November 13: now and then OneDrive overwrites an account's SyncDiagnostics.log with a
/// "Sync Verification" pass (a folder-by-folder scan, no status line). A7 read that as a format change and
/// alerted. It is neither a change nor a status: Velum keeps the last real report, with its own date.
@Suite struct VerificationPass {
    let personal = Fixture.oneDrive()

    /// Made up, in the verification pass's shape: a header, scope ids and counters, no SyncProgressState.
    static let pass = """
        Sync Diagnostics - Sync Verification

        ================================================================================
        Scope verification for 0123456789abcdef0123456789abcdef

        --------------------------------------------------------------------------------
        Scanning '%MountPoint%[0123456789abcdef0123456789abcdef]'
            - folder   '%MountPoint%[0123456789abcdef0123456789abcdef]/AAAAAAAAAAAAAAAAAAAAAAAAAAA'
        syncProblems = 3
        scanState = 1
        """

    static func write(_ text: String, in home: URL) throws -> String {
        try CompatFixture.oneDriveLog(home, text)
        return home.appending(path: "Library/Logs/OneDrive/Personal/SyncDiagnostics.log").path
    }

    @Test func theParserKnowsAVerificationPass() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let diag = try #require(OneDriveFiles.diagnostics(at: Self.write(Self.pass, in: home)))
        #expect(diag.isVerification)
        #expect(diag.progressState == nil)
        #expect(OneDriveProvider.report(from: diag) == nil)

        let normal = try #require(OneDriveFiles.diagnostics(at: Self.write("SyncProgressState: 16777216\npid = 123\n", in: home)))
        #expect(!normal.isVerification)
        #expect(normal.progressState == 16777216)
    }

    @Test func theLastRealReportIsKeptWithItsOwnDate() {
        var earlier = Diagnostics(written: Fixture.now.addingTimeInterval(-50 * 60))
        earlier.progressState = 16777216
        var pass = Diagnostics(written: Fixture.now)
        pass.isVerification = true

        #expect(OneDriveProvider.keepingStatus(pass, previous: earlier) == earlier)
        #expect(OneDriveProvider.keepingStatus(pass, previous: nil) == pass)          // just launched: nothing to keep
        var newer = Diagnostics(written: Fixture.now)
        newer.progressState = 65536
        #expect(OneDriveProvider.keepingStatus(newer, previous: earlier) == newer)    // a real report always wins

        // The kept report keeps its age: fresh now, old once its hour and grace have passed.
        let report = OneDriveProvider.report(from: OneDriveProvider.keepingStatus(pass, previous: earlier), now: Fixture.now)
        #expect(report?.state == .ok)
        #expect(report?.isOld(now: Fixture.now) == false)
        #expect(report?.isOld(now: Fixture.now.addingTimeInterval(30 * 60)) == true)
    }

    @Test func aVerificationPassIsNoChangeAndNoAlert() throws {
        let home = try CompatFixture.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try CompatFixture.oneDriveHistory(home)
        _ = try Self.write(Self.pass, in: home)
        let compat = CompatFixture.oneDrive(home)
        _ = compat.discovered([personal], now: Fixture.now)
        var e = CompatFixture.evidence([personal])
        compat.apply(&e, mappingUnknown: false, now: Fixture.now)

        let report = try #require(e.compatibility)
        #expect(report.alerting.isEmpty)
        #expect(e.accounts[0].compatibilityNote == nil)
        let check = try #require(report.checks.first { $0.name.hasPrefix("status report") })
        #expect(check.result == .fine)
        #expect(check.detail == "a verification pass this time, with no status in it")
    }
}
