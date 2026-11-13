import Foundation
import VelumStatus

/// Card T1: after every refresh the running app writes what its panel shows to `status.json`, for `velumctl` (and
/// later T2's Shortcuts and T3's widget). The schema lives in `VelumStatus` (docs/velumctl.md). The file stays
/// on this Mac, readable by this user only, so it carries file names like the panel does. `Velum --dump` and
/// `--render-panel` never write it: only a running app's refresh does.
@MainActor
final class StatusFile {
    static let shared = StatusFile()

    let url: URL
    private let queue = DispatchQueue(label: "Velum.statusfile", qos: .utility)
    /// The last write error, logged once rather than on every refresh.
    nonisolated(unsafe) private var lastError: String?

    init(url: URL = StatusDocument.defaultURL) {
        self.url = url
    }

    /// Called from `Store.refresh` with every finished refresh; `notInCloud` is the tracker's full pending list.
    func write(_ store: Store, notInCloud: PendingList, now: Date = Date()) {
        let document = Self.document(store.snapshot, summary: store.summary, state: store.overallState,
                                     notInCloud: notInCloud, now: now)
        queue.async { [self] in
            do {
                try document.write(to: url)
                if lastError != nil { debugLog("status", "Writing the status file works again") }
                lastError = nil
            } catch {
                let text = "\(error)"
                if lastError != text { debugLog("status", "Can’t write the status file for velumctl: \(text)") }
                lastError = text
            }
        }
    }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }

    static func document(_ snapshot: Snapshot, summary: String, state: SyncState, notInCloud: PendingList,
                         now: Date, stuckAfter: TimeInterval = UploadTracker.stuckAfter) -> StatusDocument {
        let info = Bundle.main.infoDictionary
        let app = AppInfo(version: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String,
                          pid: ProcessInfo.processInfo.processIdentifier)
        let services = snapshot.providers.map { provider in
            Service(id: provider.id.rawValue, name: provider.id.name, appRunning: provider.clientRunning,
                    trouble: provider.trouble, paused: provider.paused,
                    compatibility: provider.compatibility.map {
                        Compatibility(headline: $0.headline, version: $0.version, tested: $0.isTested, checksNotPassing: $0.counted.count)
                    })
        }
        let accounts = snapshot.accounts.map { account($0, stuck: snapshot.stuck.perAccount[$0.id] ?? 0) }
        let cutoff = now.addingTimeInterval(-stuckAfter)
        let files = notInCloud.files.map { file in
            let (status, reason): (VelumStatus.PendingFile.Status, String?) = switch file.status {
            case .waiting: (.waiting, nil)
            case .uploading: (.uploading, nil)
            case .failed(let why): (.failing, why)
            }
            // The same rule as the tracker's stuck listing (A3): failing at any age, or waiting past the threshold.
            return VelumStatus.PendingFile(account: file.account, path: file.path, since: file.since, status: status,
                                           reason: reason, stuck: file.isFailing || file.since <= cutoff)
        }
        let pending = Pending(total: notInCloud.total, stuck: snapshot.stuck.total, stuckAfter: stuckAfter, files: files)
        return StatusDocument(written: now, refreshEvery: Store.refreshEvery, app: app, state: AccountState(state),
                              summary: summary, lid: Lid(snapshot.lidVerdict), services: services, accounts: accounts,
                              pending: pending)
    }

    static func account(_ a: AccountStatus, stuck: Int) -> Account {
        let uploads = Uploads(pending: a.uploadsPending, failed: a.uploadsFailed, stuck: stuck, oldestWaiting: a.oldestWaiting,
                              firstFailure: a.firstFailure, covered: a.uploadsCovered, serviceBusy: a.workPending,
                              serviceBusySince: a.workingSince)
        return Account(key: a.config.key, service: a.provider.rawValue, name: a.name, state: AccountState(a.state),
                       headline: a.headline, detail: a.detail.nonEmpty, source: a.source.nonEmpty, age: a.age.nonEmpty,
                       old: a.isOld, reason: a.reason, notes: a.notes.nonEmpty, notesNeedAttention: a.notesNeedAttention,
                       headlineFromApp: a.isLive, lastChange: a.lastActivity, uploads: uploads, storage: a.storage.map(Storage.init))
    }
}

/// An account's storage as figures, beside the notes line's words, for the status file. Set by the providers that
/// know it (Google Drive, iCloud).
struct StorageFigures: Equatable {
    enum Source: Equatable { case googleDriveCache, googleSignIn, iCloudQuota }

    var limit: Int64?
    var used: Int64?
    var free: Int64?
    var usedByFiles: Int64?
    var full: Bool
    var source: Source
    var asOf: Date?
}

extension StorageFigures {
    init(_ google: GoogleStorage) {
        self.init(limit: google.limit, used: google.used, free: google.free, usedByFiles: google.usedInDrive,
                  full: google.isFull, source: google.source == .driveCache ? .googleDriveCache : .googleSignIn,
                  asOf: google.asOf)
    }

    /// `brctl quota` gives only the free space; zero or less means full.
    init(iCloudFree free: Int64, asOf: Date?) {
        self.init(free: max(0, free), full: free <= 0, source: .iCloudQuota, asOf: asOf)
    }
}

private extension Storage {
    init(_ figures: StorageFigures) {
        let source: Source = switch figures.source {
        case .googleDriveCache: .googleDriveCache
        case .googleSignIn: .googleSignIn
        case .iCloudQuota: .iCloudQuota
        }
        self.init(limit: figures.limit, used: figures.used, free: figures.free, usedByFiles: figures.usedByFiles,
                  full: figures.full, source: source, asOf: figures.asOf)
    }
}

extension AccountState {
    init(_ state: SyncState) {
        self = switch state {
        case .ok: .ok
        case .unknown: .unknown
        case .syncing: .syncing
        case .offline: .offline
        case .paused: .paused
        case .warning: .warning
        case .notRunning: .notRunning
        case .error: .error
        }
    }
}

extension Lid {
    init(_ verdict: LidVerdict) {
        self = switch verdict {
        case .safe: .safe
        case .pending(let n): .pending(n)
        case .busy(let account): .busy(account)
        case .failing(let n): .failing(n)
        case .notRunning(let service): .notRunning(service)
        case .unknown(let reason): .unknown(reason)
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
