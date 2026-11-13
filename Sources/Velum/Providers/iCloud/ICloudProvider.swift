import Foundation

/// iCloud Drive as a provider. Verified on macOS 27.3 (November 2026), all without an iCloud entitlement:
/// - File Provider's per-file flags are real in `~/Library/Mobile Documents/com~apple~CloudDocs`, so
///   uploads are tracked like OneDrive's. A new or edited file briefly reports error 4355 ("couldn't access
///   your iCloud account") while it uploads; UploadTracker treats that error as waiting, not failing.
/// - With Desktop & Documents in iCloud, `~/Desktop` and `~/Documents` are the real synced folders and
///   iCloud Drive's top folder holds symlinks to them, so all three are watched.
/// - `brctl quota` answers at once; `brctl status` takes 10–13 s and doesn't change while files upload, so
///   it runs every 10 minutes in the background as a slow account-wide check, never as live state.
/// There is no client to start or quit and no history to read: Velum records the uploads it sees finish.
final class ICloudProvider: SyncProvider, @unchecked Sendable {
    let id = ProviderID.iCloud
    static let key = "iCloudDrive"

    private let home: URL
    private let checkEvery = ICloudProvider.checkInterval
    /// How often Velum asks `brctl status`; a report older than this plus 15 minutes is old (A4).
    static let checkInterval: TimeInterval = 10 * 60
    private var config: AccountConfig?
    private var lastDiscovery = Date.distantPast

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Velum.brctl", qos: .utility)
    // Guarded by lock:
    private var report: ProviderReport?
    private var quota: Int64?
    private var lastCheck = Date.distantPast
    private var checking = false
    /// Whether the last check's `brctl status` gave a usable answer; nil before the first finishes.
    private var lastAnswered: Bool?
    /// Checks `brctl`'s answers against the tested macOS (card A7).
    let compat = ICloudCompatibility()

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var driveRoot: URL { home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory) }

    func gather(force: Bool, now: Date) -> ProviderEvidence {
        if force || now.timeIntervalSince(lastDiscovery) > 60 {
            config = discover()
            lastDiscovery = now
        }
        guard let config else { return ProviderEvidence() }
        checkIfDue(now: now, force: force)

        lock.lock()
        var report = self.report
        let quota = self.quota
        let lastCheck = self.lastCheck == .distantPast ? nil : self.lastCheck
        let checking = self.checking
        let answered = self.lastAnswered
        lock.unlock()

        var account = AccountEvidence(config: config, name: "iCloud Drive")
        let next = lastCheck.map { $0.addingTimeInterval(checkEvery) }
        if var known = report {
            known.reason = Self.reason(for: known, answered: answered, checking: checking, next: next, now: now)
            report = known
        } else {
            account.unknownReason = Self.noStatusReason(lastCheck: lastCheck, answered: answered, checking: checking, next: next)
        }
        account.report = report
        if config.watchRoots.count > 1 { account.notes.append("Desktop & Documents included") }
        var evidence = ProviderEvidence(present: true, clientRunning: nil)
        account.storageSource = quota == nil ? "none yet (brctl quota hasn’t answered)" : "brctl quota"   // S2
        if let quota {
            if quota <= 0 {
                account.notes.append("iCloud storage is full")
                account.notesNeedAttention = true    // orange, as the legend says (A4)
                evidence.trouble = "Storage full"
            } else {
                account.notes.append("\(ByteCountFormatter.string(fromByteCount: quota, countStyle: .file)) free")
            }
        }
        evidence.accounts = [account]
        compat.apply(&evidence)
        return evidence
    }

    /// iCloud Drive is on when its top folder exists and File Provider calls it synced.
    func discover() -> AccountConfig? {
        let root = driveRoot
        guard (try? root.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return nil }
        var roots = [root]
        var places = [NamedRoot(path: root.path, name: "iCloud Drive", prefixed: false)]
        // Desktop & Documents: the folder in iCloud Drive is a symlink to the real one in the home folder.
        for name in ["Desktop", "Documents"] {
            let real = home.appending(path: name, directoryHint: .isDirectory)
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: root.appending(path: name).path),
                  URL(fileURLWithPath: target).standardizedFileURL.path == real.standardizedFileURL.path,
                  (try? real.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { continue }
            roots.append(real)
            places.append(NamedRoot(path: real.path, name: name, prefixed: true))
        }
        return AccountConfig(
            key: Self.key,
            provider: .iCloud,
            folder: root,
            watchRoots: roots,
            places: places,
            fallbackName: "iCloud Drive",
            webURL: URL(string: "https://www.icloud.com/iclouddrive/")!,
            // Apple's documented page for getting deleted iCloud Drive files back (a deep link to the web
            // app's Recently Deleted sidebar doesn't exist: it opens "Item Unavailable").
            recycleBinURL: URL(string: "https://www.icloud.com/recovery"),
            storageURL: URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings"),
            keepsOwnHistory: false
        )
    }

    // MARK: brctl

    private func checkIfDue(now: Date, force: Bool) {
        lock.lock()
        let due = !checking && (now.timeIntervalSince(lastCheck) >= checkEvery || (force && report == nil))
        if due { checking = true }
        lock.unlock()
        guard due else { return }
        queue.async { [self] in
            let quotaOutput = Self.run(["quota"], timeout: 15)
            let statusOutput = Self.run(["status", "com.apple.CloudDocs"], timeout: 40)
            let quota = quotaOutput.flatMap(Self.parseQuota)
            let status = statusOutput.flatMap { Self.parseStatus($0, at: Date()) }
            let changed = compat.record(status: statusOutput, quota: quotaOutput)
            if quota == nil { debugLog("icloud", "brctl quota gave no usable answer") }
            if status == nil { debugLog("icloud", "brctl status gave no usable answer (timed out, failed or changed format)") }
            lock.lock()
            if let quota { self.quota = quota }
            if let status { self.report = status }
            // A changed shape drops what earlier checks left, instead of showing it on (card A7).
            if changed.statusChanged { self.report = nil }
            if changed.quotaChanged { self.quota = nil }
            lastCheck = Date()
            lastAnswered = status != nil
            checking = false
            lock.unlock()
        }
    }

    /// For `Velum --dump`: waits for the first background check.
    func waitForFirstCheck(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let done = lastCheck != .distantPast
            lock.unlock()
            if done { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// `brctl status com.apple.CloudDocs`: one line per container, e.g.
    /// `<c{1}m.a{3}e.C{7}s[1] foreground {client:idle server:full-sync|… sync:oob-sync-ack last-sync:…, caught-up, …}`.
    /// Undocumented, so only "client idle and caught up" counts as healthy; anything else is unknown.
    static func parseStatus(_ output: String, at time: Date) -> ProviderReport? {
        let clean = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard let line = clean.split(separator: "\n").first(where: { $0.hasPrefix("<") }) else { return nil }
        let client = line.range(of: #"client:[^\s]+"#, options: .regularExpression)
            .map { String(line[$0].dropFirst("client:".count)) }
        let healthy = client == "idle" && line.contains("caught-up")
        return ProviderReport(label: "iCloud status", written: time,
                              state: healthy ? .ok : .unknown,
                              headline: healthy ? "Up to date" : "Can’t tell", every: checkInterval)
    }

    // MARK: Reasons (A4): why the row can't tell, and what would end it

    /// No status yet: the first check is running (it takes 10 to 13 s), or iCloud didn't answer.
    static func noStatusReason(lastCheck: Date?, answered: Bool?, checking: Bool, next: Date?) -> String {
        guard let lastCheck, answered == false else {
            return "Checking iCloud now. This takes about 15 seconds."
        }
        if checking { return "iCloud didn’t answer the \(RelTime.clock(lastCheck)) check. Velum is asking again now." }
        let again = next.map { " Velum tries again at \(RelTime.clock($0))." } ?? ""
        return "iCloud didn’t answer the \(RelTime.clock(lastCheck)) check.\(again)"
    }

    /// The reason for a check that left the status unknown, or one that has gone old; nil for a fresh, healthy one.
    static func reason(for report: ProviderReport, answered: Bool?, checking: Bool, next: Date?, now: Date) -> String? {
        let again = checking ? " Velum is checking again now." : next.map { " Velum checks again at \(RelTime.clock($0))." } ?? ""
        if report.isOld(now: now) {
            // After sleep no check may have run at all, so "hasn't answered" only after one that failed.
            let age = Reasons.duration(now.timeIntervalSince(report.written))
            let silent = answered == false ? "; it hasn’t answered since" : ""
            return "iCloud’s last answer, at \(RelTime.clock(report.written)), is \(age) old\(silent).\(again)"
        }
        guard report.state == .unknown else { return nil }
        return "At \(RelTime.clock(report.written)) iCloud didn’t say it’s caught up.\(again)"
    }

    /// `brctl quota`: "1272173412087 bytes of quota remaining in personal account".
    static func parseQuota(_ output: String) -> Int64? {
        guard let match = output.range(of: #"-?\d+(?= bytes of quota remaining)"#, options: .regularExpression) else { return nil }
        return Int64(output[match])
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        // Read while it runs, so a full pipe can't stall it.
        var data = Data()
        let reader = DispatchQueue(label: "Velum.brctl.read")
        reader.async { data = pipe.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        reader.sync {}
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
