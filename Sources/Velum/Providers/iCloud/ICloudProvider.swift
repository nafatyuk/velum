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
    private let checkEvery: TimeInterval = 10 * 60
    private var config: AccountConfig?
    private var lastDiscovery = Date.distantPast

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Velum.brctl", qos: .utility)
    // Guarded by lock:
    private var report: ProviderReport?
    private var quota: Int64?
    private var lastCheck = Date.distantPast
    private var checking = false

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
        let report = self.report
        let quota = self.quota
        lock.unlock()

        var account = AccountEvidence(config: config, name: "iCloud Drive")
        account.report = report
        if config.watchRoots.count > 1 { account.notes.append("Desktop & Documents included") }
        var evidence = ProviderEvidence(present: true, clientRunning: nil)
        if let quota {
            if quota <= 0 {
                account.notes.append("iCloud storage is full")
                evidence.trouble = "Storage full"
            } else {
                account.notes.append("\(ByteCountFormatter.string(fromByteCount: quota, countStyle: .file)) free")
            }
        }
        evidence.accounts = [account]
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
            let quota = Self.run(["quota"], timeout: 15).flatMap(Self.parseQuota)
            let status = Self.run(["status", "com.apple.CloudDocs"], timeout: 40).flatMap { Self.parseStatus($0, at: Date()) }
            lock.lock()
            if let quota { self.quota = quota }
            if let status { self.report = status }
            lastCheck = Date()
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
                              headline: healthy ? "Up to date" : "Status unknown")
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
