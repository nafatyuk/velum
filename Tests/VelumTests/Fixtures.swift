import Foundation
@testable import Velum

/// Made-up accounts and evidence. Never real paths or names from this Mac.
enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func oneDrive(_ key: String = "Personal", name: String = "Personal") -> AccountConfig {
        let folder = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/OneDrive-\(name)")
        return AccountConfig(key: key, provider: .oneDrive, folder: folder, watchRoots: [folder],
                             places: [NamedRoot(path: folder.path, name: folder.lastPathComponent, prefixed: false),
                                      NamedRoot(path: "/Users/test/OneDrive", name: folder.lastPathComponent, prefixed: false)],
                             fallbackName: name, webURL: URL(string: "https://onedrive.live.com/")!)
    }

    static func iCloud() -> AccountConfig {
        let root = URL(fileURLWithPath: "/Users/test/Library/Mobile Documents/com~apple~CloudDocs")
        let desktop = URL(fileURLWithPath: "/Users/test/Desktop")
        let documents = URL(fileURLWithPath: "/Users/test/Documents")
        return AccountConfig(key: ICloudProvider.key, provider: .iCloud, folder: root,
                             watchRoots: [root, desktop, documents],
                             places: [NamedRoot(path: root.path, name: "iCloud Drive", prefixed: false),
                                      NamedRoot(path: desktop.path, name: "Desktop", prefixed: true),
                                      NamedRoot(path: documents.path, name: "Documents", prefixed: true)],
                             fallbackName: "iCloud Drive", webURL: URL(string: "https://www.icloud.com/iclouddrive/")!,
                             keepsOwnHistory: false)
    }

    static func report(_ state: SyncState, _ headline: String, label: String = "OneDrive report") -> ProviderReport {
        ProviderReport(label: label, written: now.addingTimeInterval(-600), state: state, headline: headline)
    }

    static func evidence(_ config: AccountConfig, running: Bool = true, exact: String? = nil,
                         report: ProviderReport? = nil) -> AccountEvidence {
        var e = AccountEvidence(config: config, name: config.fallbackName)
        e.running = running
        e.exactStatus = exact
        e.report = report
        return e
    }

    static func status(_ evidence: AccountEvidence, transfer: TransferInfo? = nil, uploads: UploadSummary? = UploadSummary(),
                       watching: Bool = true) -> AccountStatus {
        Collector.status(evidence, transfer: transfer, uploads: uploads, watchingUploads: watching, now: now)
    }
}
