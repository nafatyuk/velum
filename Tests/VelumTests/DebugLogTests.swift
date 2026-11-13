import Foundation
import Testing
@testable import Velum

@Suite struct DebugLogging {
    func makeLog(maxSize: UInt64 = 2_000_000) -> (DebugLog, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-log-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "velum-test-\(UUID().uuidString)")!
        return (DebugLog(directory: dir, defaults: defaults, maxSize: maxSize), dir, defaults)
    }

    @Test func offWritesNothing() {
        let (log, dir, _) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        log.log("status", "should not appear")
        log.flush()
        #expect(!FileManager.default.fileExists(atPath: log.file.path))
    }

    @Test func onWritesTimestampedLinesAndRemembersTheSwitch() throws {
        let (log, dir, defaults) = makeLog()
        defer { try? FileManager.default.removeItem(at: dir) }
        log.isEnabled = true
        log.log("status", "Personal: ok → syncing")
        log.flush()
        let text = try String(contentsOf: log.file, encoding: .utf8)
        #expect(text.contains("[log] Debug logging turned on"))
        #expect(text.contains("[status] Personal: ok → syncing"))
        #expect(defaults.bool(forKey: DebugLog.defaultsKey))
        log.isEnabled = false
        log.log("status", "after off")
        log.flush()
        let after = try String(contentsOf: log.file, encoding: .utf8)
        #expect(after.contains("Debug logging turned off"))
        #expect(!after.contains("after off"))
    }

    @Test func rotatesWhenLarge() throws {
        let (log, dir, _) = makeLog(maxSize: 200)
        defer { try? FileManager.default.removeItem(at: dir) }
        log.isEnabled = true
        for i in 0..<20 { log.log("status", "line \(i) with some padding to grow the file") }
        log.flush()
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Velum.1.log").path))
        let size = try FileManager.default.attributesOfItem(atPath: log.file.path)[.size] as? UInt64 ?? 0
        #expect(size < 400)
    }

    @Test func describesOnlyMeaningfulChanges() {
        var before = Snapshot()
        before.providers = [ProviderStatus(id: .oneDrive, clientRunning: true), ProviderStatus(id: .googleDrive, clientRunning: true)]
        let ok = Fixture.status(Fixture.evidence(Fixture.oneDrive(), report: Fixture.report(.ok, "Up to date")))
        before.accounts = [ok]
        let first = DebugLog.changes(from: nil, to: before)
        #expect(first.contains("OneDrive: found · app running"))
        #expect(first.contains { $0.hasPrefix("Personal [OneDrive]: appeared · Up to date") })
        #expect(first.contains("Lid: safe"))

        #expect(DebugLog.changes(from: before, to: before).isEmpty)   // nothing changed, nothing logged

        var after = before
        after.providers = [ProviderStatus(id: .oneDrive, clientRunning: false)]
        after.accounts = [Fixture.status(Fixture.evidence(Fixture.oneDrive(), running: false))]
        let lines = DebugLog.changes(from: before, to: after)
        #expect(lines.contains("OneDrive: app stopped"))
        #expect(lines.contains("Google Drive: gone (no live accounts)"))
        #expect(lines.contains { $0.hasPrefix("Personal: ok → notRunning · Not running, so nothing is syncing") })
        #expect(lines.contains("Lid: notRunning(\"OneDrive\")"))
    }
}
