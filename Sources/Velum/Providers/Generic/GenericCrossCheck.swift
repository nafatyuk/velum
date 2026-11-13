import AppKit

/// Card C3's cross-check, test-only: `Velum --cross-check [seconds]` runs the CloudStorage folders the deep
/// adapters claim (OneDrive's, Google Drive's) through the generic tier as well, and compares the two views of
/// each folder: the files waiting, uploading and failing, every 5 seconds for `seconds` (60 by default).
/// It also shows which app the generic tier identifies for each folder, from its File Provider extension.
///
/// Both sides start watching at the same moment with their own throwaway saved state (removed at the end), so
/// the running Velum's saved state is never touched and both see the same changes. Nothing is written into any
/// cloud folder: write a test file yourself while it runs to watch both sides follow it. It prints folder
/// names, which can hold addresses: keep its output out of the repository.
enum GenericCrossCheck {
    @MainActor
    static func run(seconds: TimeInterval) {
        let deep = Collector(providers: [OneDriveProvider(), GoogleDriveProvider()])
        let generic = GenericProvider()
        generic.claimsNothing = true
        let wide = Collector(providers: [generic])

        let suites = ["velum-crosscheck-deep-\(getpid())", "velum-crosscheck-generic-\(getpid())"]
        guard let deepDefaults = UserDefaults(suiteName: suites[0]), let wideDefaults = UserDefaults(suiteName: suites[1]) else {
            Swift.print("Cross-check: couldn’t make throwaway saved state")
            return
        }
        defer {
            // Empty both, wait for the preferences daemon, then remove their files: a bare removePersistentDomain
            // right before exit left one behind in the first live run.
            for (suite, defaults) in zip(suites, [deepDefaults, wideDefaults]) {
                for key in defaults.dictionaryRepresentation().keys { defaults.removeObject(forKey: key) }
                defaults.synchronize()
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let prefs = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Preferences")
            for suite in suites { try? FileManager.default.removeItem(at: prefs.appending(path: suite + ".plist")) }
        }
        let deepTracker = UploadTracker(defaults: deepDefaults)
        let wideTracker = UploadTracker(defaults: wideDefaults)
        let first = (deep.collect(force: true), wide.collect(force: true))
        func roots(_ s: Snapshot) -> [String: [URL]] {
            Dictionary(s.accounts.map { ($0.config.key, $0.config.watchRoots) }, uniquingKeysWith: { a, _ in a })
        }
        deepTracker.watch(roots(first.0))
        wideTracker.watch(roots(first.1))

        // Pair each deep account with the generic row for the same root (Google Drive opens "My Drive" inside it).
        func root(_ account: AccountStatus) -> String { (account.config.watchRoots.first ?? account.config.folder).standardizedFileURL.path }
        let byRoot = Dictionary(first.1.accounts.map { (root($0), $0) }, uniquingKeysWith: { a, _ in a })
        let pairs = first.0.accounts.compactMap { account -> (deep: AccountStatus, generic: AccountStatus)? in
            byRoot[root(account)].map { (account, $0) }
        }
        let unpaired = first.1.accounts.filter { g in !pairs.contains { $0.generic.id == g.id } }
        Swift.print("Cross-check (card C3): \(pairs.count) folder\(pairs.count == 1 ? "" : "s") seen by both a deep adapter and the generic tier; \(unpaired.count) by the generic tier alone")
        for pair in pairs {
            Swift.print("• \(pair.generic.config.folder.lastPathComponent): \(pair.deep.provider.name) adapter [\(pair.deep.id)] · generic [\(pair.generic.id)]")
            Swift.print("    " + GenericText.dumpLine(GenericProvider.identify(pair.generic.config.folder)))
        }
        for account in unpaired {
            Swift.print("• \(account.config.folder.lastPathComponent): generic tier only [\(account.id)]")
            Swift.print("    " + GenericText.dumpLine(GenericProvider.identify(account.config.folder)))
        }

        var disagreements = 0
        let end = Date().addingTimeInterval(max(5, seconds))
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            let a = deepTracker.summary(), b = wideTracker.summary()
            let stamp = Date().formatted(date: .omitted, time: .standard)
            for pair in pairs {
                let x = counts(a.accounts[pair.deep.id]), y = counts(b.accounts[pair.generic.id])
                let agree = x == y
                if !agree { disagreements += 1 }
                Swift.print("\(stamp) \(pair.generic.config.folder.lastPathComponent): adapter \(x) · generic \(y) · \(agree ? "agree" : "DIFFER")")
            }
        } while Date() < end
        Swift.print(disagreements == 0 ? "Cross-check: the two views agreed at every sample."
                                       : "Cross-check: \(disagreements) sample\(disagreements == 1 ? "" : "s") differed.")
    }

    private static func counts(_ summary: UploadSummary?) -> String {
        guard let summary else { return "not watched" }
        return "\(summary.waiting) waiting, \(summary.uploading) uploading, \(summary.failed.count) failing\(summary.coverageGap ? " (gap)" : "")"
    }
}
