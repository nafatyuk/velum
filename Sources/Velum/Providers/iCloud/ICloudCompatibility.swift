import Foundation

/// iCloud's `brctl` answers, checked every time Velum asks (card A7). `brctl` ships with macOS, so macOS's
/// version is the one tested. Recorded from the background `brctl` queue, applied on the collector's queue.
/// - **status report** (`brctl status`): a container line with a `client:` state. If it changes shape, or
///   `brctl` is gone, the report is dropped (not kept from an earlier check) and the row says why;
/// - **storage** (`brctl quota`): "N bytes of quota remaining". If it changes shape, the "free" note is
///   dropped; recorded only, no reason line and no alert (Fable: storage is optional).
/// A timeout or a failed run is a passing hiccup: it keeps the last result and never counts as a change.
final class ICloudCompatibility: @unchecked Sendable {
    var version: () -> String = { ClientVersion.macOS }
    var brctlExists: () -> Bool = { FileManager.default.isExecutableFile(atPath: "/usr/bin/brctl") }

    private let lock = NSLock()
    // Guarded by lock:
    private var status: InternalCheck?
    private var quota: InternalCheck?
    private var logged: CompatibilityReport?

    /// Records one round of answers (nil: no answer) and says which ones changed shape, so the provider drops
    /// what it kept from earlier rounds.
    @discardableResult
    func record(status statusOutput: String?, quota quotaOutput: String?) -> (statusChanged: Bool, quotaChanged: Bool) {
        let exists = brctlExists()
        let client = CompatibilityReport(provider: .iCloud, version: version()).client
        let statusCheck = Self.statusResult(statusOutput, brctlExists: exists).map { result, detail in
            InternalCheck(name: "status report (brctl status)", result: result, detail: detail, phrase: "status report",
                          note: result == .changed ? CompatibilityText.iCloudReport(client) : nil)
        }
        let quotaCheck = Self.quotaResult(quotaOutput, brctlExists: exists).map { result, detail in
            InternalCheck(name: "storage (brctl quota)", result: result, detail: detail, quiet: true, phrase: "storage figure")
        }
        lock.lock()
        defer { lock.unlock() }
        if let statusCheck { status = statusCheck }
        if let quotaCheck { quota = quotaCheck }
        return (statusCheck?.result == .changed, quotaCheck?.result == .changed)
    }

    /// Before the evidence leaves the provider: the row's reason, and the report.
    func apply(_ evidence: inout ProviderEvidence) {
        var report = CompatibilityReport(provider: .iCloud, version: version())
        lock.lock()
        report.checks = [status, quota].compactMap { $0 }
        var logged = self.logged
        report.record(into: &evidence, logged: &logged)
        self.logged = logged
        lock.unlock()
    }

    /// `brctl status`: a line starting with `<` and holding `client:` and `server:` states. nil: no answer.
    static func statusResult(_ output: String?, brctlExists: Bool) -> (InternalCheck.Result, String)? {
        guard brctlExists else { return (.changed, "/usr/bin/brctl is gone") }
        guard let output else { return nil }
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let line = clean.split(separator: "\n").first(where: { $0.hasPrefix("<") }) else {
            return (.changed, "no container line")
        }
        guard let client = line.range(of: #"client:[^\s]+"#, options: .regularExpression), line.contains("server:") else {
            return (.changed, "no client: and server: states")
        }
        return (.fine, String(line[client]) + (line.contains("caught-up") ? ", caught-up" : ""))
    }

    /// `brctl quota`: "N bytes of quota remaining". nil: no answer.
    static func quotaResult(_ output: String?, brctlExists: Bool) -> (InternalCheck.Result, String)? {
        guard brctlExists else { return (.changed, "/usr/bin/brctl is gone") }
        guard let output else { return nil }
        return ICloudProvider.parseQuota(output) == nil ? (.changed, "no “bytes of quota remaining” figure") : (.fine, "")
    }
}
