import Foundation

/// Live transfers for one account, from the progress macOS's File Provider publishes for the OneDrive
/// folder (the same progress Finder's sidebar spinner shows). Real time, public API, and it keeps working
/// when OneDrive's own menu bar icons are hidden.
struct TransferInfo: Equatable {
    var uploadingFiles = 0
    var downloadingFiles = 0
    /// Per-file transfers File Provider publishes without saying which direction (OneDrive's uploads look
    /// like this). UploadTracker usually knows about the same files.
    var otherFiles = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0

    var files: Int { uploadingFiles + downloadingFiles + otherFiles }
    var isActive: Bool { files > 0 }

    var bytesText: String? {
        guard bytesTotal > 0 else { return nil }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "\(f.string(fromByteCount: bytesDone)) of \(f.string(fromByteCount: bytesTotal))"
    }
}

@MainActor
final class TransferMonitor {
    private final class Entry {
        let account: String
        let progress: Progress
        let isRoot: Bool
        var lastCompleted: Int64
        var lastFilesDone = 0
        var lastMovement: Date

        init(account: String, progress: Progress, isRoot: Bool) {
            self.account = account
            self.progress = progress
            self.isRoot = isRoot
            self.lastCompleted = progress.completedUnitCount
            self.lastMovement = Date()
        }
    }

    /// A transfer that hasn't moved for this long is treated as stalled, not as "syncing".
    private let stallAfter: TimeInterval = 120

    private var subscriptions: [String: (folder: URL, token: Any)] = [:]
    private var entries: [ObjectIdentifier: Entry] = [:]
    var onChange: (() -> Void)?

    /// Subscribes to each account folder once; drops folders that are gone.
    func watch(_ folders: [String: URL]) {
        for (key, sub) in subscriptions where folders[key] != sub.folder {
            Progress.removeSubscriber(sub.token)
            subscriptions[key] = nil
            entries = entries.filter { $0.value.account != key }
        }
        for (key, folder) in folders where subscriptions[key] == nil {
            let rootPath = folder.standardizedFileURL.path
            let token = Progress.addSubscriber(forFileURL: folder) { [weak self] progress in
                let id = ObjectIdentifier(progress)
                let isRoot = progress.fileURL?.standardizedFileURL.path == rootPath
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.entries[id] = Entry(account: key, progress: progress, isRoot: isRoot)
                        self?.onChange?()
                    }
                }
                return {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self?.entries[id] = nil
                            self?.onChange?()
                        }
                    }
                }
            }
            subscriptions[key] = (folder, token)
        }
    }

    /// Bytes or finished-file count moving both count as progress.
    private func noteMovement(_ entry: Entry, now: Date) {
        let p = entry.progress
        let filesDone = (p.userInfo[.fileCompletedCountKey] as? NSNumber)?.intValue ?? 0
        if p.completedUnitCount != entry.lastCompleted || filesDone != entry.lastFilesDone {
            entry.lastCompleted = p.completedUnitCount
            entry.lastFilesDone = filesDone
            entry.lastMovement = now
        }
    }

    /// Current transfers per account key.
    func snapshot(now: Date = Date()) -> [String: TransferInfo] {
        var result: [String: TransferInfo] = [:]
        let byAccount = Dictionary(grouping: entries.values, by: \.account)

        for (account, list) in byAccount {
            var info = TransferInfo()
            for operation in [Progress.FileOperationKind.uploading, .downloading] {
                let matching = list.filter { $0.progress.fileOperationKind == operation && !$0.progress.isFinished }
                for entry in matching { noteMovement(entry, now: now) }
                // Drop stalled transfers first, so a stuck folder-level total can't hide active files.
                let moving = matching.filter { now.timeIntervalSince($0.lastMovement) < stallAfter }
                // The folder-level progress already totals the per-file ones; count it alone when present.
                let roots = moving.filter(\.isRoot)
                for entry in (roots.isEmpty ? moving : roots) {
                    let p = entry.progress
                    let total = (p.userInfo[.fileTotalCountKey] as? NSNumber)?.intValue
                    let done = (p.userInfo[.fileCompletedCountKey] as? NSNumber)?.intValue ?? 0
                    let remaining = total.map { max(0, $0 - done) } ?? 1
                    guard remaining > 0 || p.completedUnitCount < p.totalUnitCount else { continue }

                    if operation == .uploading { info.uploadingFiles += max(remaining, 1) } else { info.downloadingFiles += max(remaining, 1) }
                    if p.totalUnitCount > 0 {
                        info.bytesTotal += p.totalUnitCount
                        info.bytesDone += min(p.completedUnitCount, p.totalUnitCount)
                    }
                }
            }
            for entry in list where entry.progress.fileOperationKind == nil && !entry.isRoot && !entry.progress.isFinished {
                noteMovement(entry, now: now)
                guard now.timeIntervalSince(entry.lastMovement) < stallAfter else { continue }
                info.otherFiles += 1
            }
            if info.isActive { result[account] = info }
        }
        return result
    }
}
