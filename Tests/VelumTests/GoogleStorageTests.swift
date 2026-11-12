import Foundation
import Testing
@testable import Velum

/// A tiny protobuf writer, to build records shaped like Google Drive's cached account record.
enum PB {
    static func varint(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
        return out
    }
    static func int(_ field: Int, _ v: UInt64) -> [UInt8] { varint(UInt64(field << 3)) + varint(v) }
    static func msg(_ field: Int, _ body: [UInt8]) -> [UInt8] { varint(UInt64(field << 3 | 2)) + varint(UInt64(body.count)) + body }
    static func text(_ field: Int, _ s: String) -> [UInt8] { msg(field, Array(s.utf8)) }

    /// Field 2 → 3 → 1 holds the quota, beside text fields like the ones Drive keeps (made-up values).
    static func account(limit: UInt64?, used: UInt64, remaining: UInt64?, user: UInt64? = nil) -> Data {
        var quota = int(3, used) + int(6, 1) + int(10, used)
        if let limit { quota = int(1, limit) + quota + int(7, limit) }
        if let remaining { quota += int(8, remaining) }
        if let user { quota += int(9, user) }
        let profile = int(1, 1) + text(3, "Test Person") + text(8, "test@example.com")
        return Data(int(1, 1) + msg(2, msg(1, profile) + msg(3, msg(1, quota) + msg(12, int(1, 2)))) + int(5, 1))
    }
}

@Suite struct GoogleStorageFromDrivesCache {
    let gib: UInt64 = 1 << 30

    @Test func readsTheQuota() {
        let blob = PB.account(limit: 400 * gib, used: 186 * gib, remaining: 214 * gib, user: 128 * gib)
        let s = GoogleDriveProvider.parseStorage(blob, asOf: Fixture.now)
        #expect(s?.limit == Int64(400 * gib))
        #expect(s?.used == Int64(186 * gib))
        #expect(s?.usedInDrive == Int64(128 * gib))
        #expect(s?.source == .driveCache)
        #expect(s.map(GoogleDriveProvider.storageNote) == "214 GB free of 400 GB")
    }

    @Test func refusesFiguresThatDontAddUp() {
        // limit − used ≠ remaining: the record changed shape, so show nothing rather than a wrong number.
        #expect(GoogleDriveProvider.parseStorage(PB.account(limit: 400 * gib, used: 186 * gib, remaining: 99 * gib), asOf: Fixture.now) == nil)
        #expect(GoogleDriveProvider.parseStorage(PB.account(limit: 400 * gib, used: 186 * gib, remaining: nil), asOf: Fixture.now) == nil)
        #expect(GoogleDriveProvider.parseStorage(Data([0x0a, 0xff]), asOf: Fixture.now) == nil)
        #expect(GoogleDriveProvider.parseStorage(Data(), asOf: Fixture.now) == nil)
    }

    @Test func unlimitedPlansShowUsage() {
        let s = GoogleDriveProvider.parseStorage(PB.account(limit: nil, used: 3 * gib + gib / 2, remaining: nil), asOf: Fixture.now)
        #expect(s?.limit == nil)
        #expect(s.map(GoogleDriveProvider.storageNote) == "3.5 GB used")
    }

    @Test func thresholds() {
        func storage(limit: UInt64, free: UInt64) -> GoogleStorage {
            GoogleStorage(limit: Int64(limit), used: Int64(limit - free), usedInDrive: nil, source: .driveCache, asOf: Fixture.now)
        }
        let roomy = storage(limit: 2048 * gib, free: 150 * gib)       // 93% used, but 150 GB left: quiet
        #expect(!roomy.isAlmostFull && !roomy.isFull)
        let tight = storage(limit: 15 * gib, free: gib)               // 93% used, 1 GB left
        #expect(tight.isAlmostFull)
        #expect(GoogleDriveProvider.storageNote(tight) == "Almost full · 1.0 GB free of 15 GB")
        let full = storage(limit: 15 * gib, free: 50 << 20)           // 50 MB left
        #expect(full.isFull && !full.isAlmostFull)
        #expect(GoogleDriveProvider.storageNote(full) == "Storage full · shared with Gmail and Photos")
        #expect(GoogleDriveProvider.storageHelp(full).hasPrefix("Google storage, shared by Drive, Gmail and Photos"))
    }

    @Test func sizesReadLikeGooglesOwn() {
        #expect(GoogleDriveProvider.size(Int64(400 * gib)) == "400 GB")
        #expect(GoogleDriveProvider.size(Int64(2048 * gib)) == "2.0 TB")
        #expect(GoogleDriveProvider.size(Int64(512 << 20)) == "512 MB")
    }
}

@Suite struct GoogleDrivePause {
    let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c")

    @Test func pausedSaysSo() {
        let config = GoogleDriveProvider.config(email: "a@b.c", root: root)
        let quiet = Fixture.status(Fixture.evidence(config, report: GoogleDriveProvider.pausedReport(now: Fixture.now)))
        #expect(quiet.state == .paused)
        #expect(quiet.headline == "Paused")
        var uploads = UploadSummary()
        uploads.waiting = 2
        let waiting = Fixture.status(Fixture.evidence(config, report: GoogleDriveProvider.pausedReport(now: Fixture.now)), uploads: uploads)
        #expect(waiting.headline == "Paused, 2 files waiting")
    }

    @Test func eachServiceNamesItsDeletedFiles() {
        #expect(ProviderID.iCloud.deletedFilesLabel == "Recover Deleted Files…")
        #expect(ProviderID.googleDrive.deletedFilesLabel == "Trash")
        #expect(ProviderID.oneDrive.deletedFilesLabel == "Recycle Bin")
    }
}

@MainActor
@Suite struct StorageAlerts {
    @Test func fullStorageAlertsOnceButNeverChangesTheRow() {
        let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-a@b.c")
        var e = Fixture.evidence(GoogleDriveProvider.config(email: "a@b.c", root: root),
                                 report: GoogleDriveProvider.report(queued: 0, now: Fixture.now))
        e.storageFull = true
        e.notesNeedAttention = true
        let account = Fixture.status(e)
        #expect(account.state == .ok)                      // storage is optional: the row stays as sync says
        var s = Snapshot()
        s.providers = [ProviderStatus(id: .googleDrive, clientRunning: true)]
        s.accounts = [account]
        #expect(s.lidVerdict == .safe)
        let notifier = Notifier()
        var shown: [String] = []
        notifier.fallback = { title, _, _ in shown.append(title) }
        notifier.update(s, enabled: true, now: Fixture.now)
        notifier.update(s, enabled: true, now: Fixture.now.addingTimeInterval(31))
        notifier.update(s, enabled: true, now: Fixture.now.addingTimeInterval(90))
        #expect(shown == ["Google Drive storage full · a@b.c"])
    }
}
