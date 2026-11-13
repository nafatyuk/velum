import Foundation
import Testing
@testable import Velum

// S1: the guided first run. Every account, app and list here is made up.

private func defaults() -> UserDefaults {
    let name = "velum-tests.first-run.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

private func json(_ text: String) -> Data { Data(text.utf8) }

private let oneDriveID = "com.microsoft.OneDrive"
private let googleID = "com.google.drivefs"

@Suite struct FirstLaunchState {
    @Test func onlyATrueFirstLaunchStartsIt() {
        #expect(FirstRun.launch(installedBefore: false, done: false, pending: false) == .init(pending: true, openPanel: true))
        // An install that has run before (it wrote loginItemConfigured) gets it only from ••• → Setup….
        #expect(FirstRun.launch(installedBefore: true, done: false, pending: false) == .init(pending: false, openPanel: false))
        // Quit before the panel was ever closed: still pending, but the panel never opens by itself a second time.
        #expect(FirstRun.launch(installedBefore: true, done: false, pending: true) == .init(pending: true, openPanel: false))
        // Done is for good.
        #expect(FirstRun.launch(installedBefore: false, done: true, pending: false) == .init(pending: false, openPanel: false))
        #expect(FirstRun.launch(installedBefore: true, done: true, pending: true) == .init(pending: false, openPanel: false))
    }

    @Test func freshDefaultsOpenThePanelOnce() {
        let d = defaults()
        #expect(FirstRun.noteLaunch(d))
        #expect(FirstRun.isPending(d))
        d.set(true, forKey: FirstRun.installedKey)   // what LoginItem.enableOnFirstLaunch writes right after
        #expect(!FirstRun.noteLaunch(d))             // the next launch: no second opening
        #expect(FirstRun.isPending(d))               // the panel still opens on it, as it was never closed
        FirstRun.markDone(d)
        #expect(!FirstRun.isPending(d))
        #expect(!FirstRun.noteLaunch(d))
        #expect(d.object(forKey: FirstRun.pendingKey) == nil)
    }

    @MainActor @Test func closingThePanelCountsAsDone() {
        let d = defaults()
        FirstRun.noteLaunch(d)
        FirstRun.wentToSettings = false
        FirstRun.panelClosed(d)                       // Esc or a click elsewhere
        #expect(!FirstRun.isPending(d))
        #expect(d.bool(forKey: FirstRun.doneKey))
    }

    @MainActor @Test func goingToMenuBarSettingsShowsItOnceMore() {
        let d = defaults()
        FirstRun.noteLaunch(d)
        FirstRun.wentToSettings = true                // its own Open Menu Bar Settings closed the panel
        FirstRun.panelClosed(d)
        #expect(FirstRun.isPending(d))                // back at the next opening, its switches read afresh
        #expect(!FirstRun.wentToSettings)
        FirstRun.panelClosed(d)                       // then any close is done
        #expect(!FirstRun.isPending(d))
        // From ••• → Setup… after Done, the same: once more after Menu Bar settings, then gone.
        FirstRun.wentToSettings = true
        FirstRun.panelClosed(d)
        #expect(FirstRun.isPending(d))
        FirstRun.panelClosed(d)
        #expect(!FirstRun.isPending(d))
    }

    @Test func anExistingInstallIsLeftAlone() {
        let d = defaults()
        d.set(true, forKey: FirstRun.installedKey)
        #expect(!FirstRun.noteLaunch(d))
        #expect(!FirstRun.isPending(d))
        #expect(d.object(forKey: FirstRun.pendingKey) == nil)   // nothing written
    }
}

@Suite struct AllowInTheMenuBarList {
    @Test func readsTheShapeSeenOnMacOS27() {
        let entries = MenuBarAllowList.parse(json("""
            {"com.microsoft.OneDrive": {"lastKnownLocalizedName": "OneDrive", "rawBundleId": "com.microsoft.OneDrive", "isAllowed": true},
             "com.example.chat": {"lastKnownLocalizedName": "Chat", "rawBundleId": "com.example.chat", "isAllowed": false}}
            """))
        #expect(entries == [oneDriveID: .allowed, "com.example.chat": .notAllowed])
    }

    @Test func anEntryWithoutARealSwitchIsUnreadable() {
        let entries = MenuBarAllowList.parse(json("""
            {"a": {"isAllowed": true}, "b": {"rawBundleId": "b"}, "c": {"isAllowed": 1}, "d": {"isAllowed": "yes"}}
            """))
        #expect(entries == ["a": .allowed, "b": .unreadable, "c": .unreadable, "d": .unreadable])
    }

    @Test func otherShapesCantBeRead() {
        #expect(MenuBarAllowList.parse(json("not json")) == nil)
        #expect(MenuBarAllowList.parse(json("[1, 2]")) == nil)
        #expect(MenuBarAllowList.parse(json(#"{"a": true}"#)) == nil)                     // entries aren't objects
        #expect(MenuBarAllowList.parse(json(#"{"a": {"allowed": true}}"#)) == nil)         // no readable switch at all
        #expect(MenuBarAllowList.parse(Data()) == nil)
        #expect(MenuBarAllowList.parse(json("{}")) == [:])                                  // read, and nobody switched
    }

    @Test func iconStateNeverGuesses() {
        let list = MenuBarAllowList(entries: [oneDriveID: .allowed, googleID: .notAllowed, "com.example.box": .unreadable])
        #expect(VendorIcon.of(bundleID: oneDriveID, drawsIcon: true, list: list, running: true) == .on(running: true))
        #expect(VendorIcon.of(bundleID: googleID, drawsIcon: true, list: list, running: true) == .off)
        #expect(VendorIcon.of(bundleID: "com.example.box", drawsIcon: false, list: list, running: true) == .cantTell(.entryUnreadable))
        // No entry: macOS's default (allowed) only for an app known to draw an icon.
        #expect(VendorIcon.of(bundleID: "com.example.known", drawsIcon: true, list: list, running: false) == .on(running: false))
        #expect(VendorIcon.of(bundleID: "com.example.dropbox", drawsIcon: false, list: list, running: true) == .cantTell(.notListed))
        #expect(VendorIcon.of(bundleID: nil, drawsIcon: false, list: list, running: nil) == .cantTell(.unknownApp))
        // The list unreadable: can't tell, even for OneDrive.
        #expect(VendorIcon.of(bundleID: oneDriveID, drawsIcon: true, list: .unreadable, running: true) == .cantTell(.listUnreadable))
    }

    @Test func velumsOwnIconSwitchedOffIsNoticed() {
        let list = MenuBarAllowList(entries: ["com.example.velum": .notAllowed])
        #expect(FirstRun.ownIconOff(list, bundleID: "com.example.velum"))
        #expect(!FirstRun.ownIconOff(MenuBarAllowList(entries: [:]), bundleID: "com.example.velum"))
        #expect(!FirstRun.ownIconOff(.unreadable, bundleID: "com.example.velum"))
        #expect(!FirstRun.ownIconOff(list, bundleID: nil))
    }
}

@Suite struct FoundClouds {
    /// The made-up "beta" panel: two OneDrive accounts, iCloud Drive, one Google account, a Dropbox folder
    /// and an unnamed AcmeSync folder.
    private let snapshot = SampleData.snapshot("beta", now: Fixture.now)!
    private func appOf(_ folder: URL) -> String? { folder.lastPathComponent == "Dropbox" ? "com.example.dropbox" : nil }

    @Test func summaryFromMadeUpAccounts() {
        let clouds = FirstRun.clouds(snapshot, list: MenuBarAllowList(entries: [:]), appOf: appOf, isRunning: { _ in true })
        #expect(FirstRun.summary(clouds) == "OneDrive: 2 accounts · iCloud Drive · Google Drive: 1 account · Dropbox (beta) · AcmeSync (beta)")
        #expect(clouds.map(\.icon) == [.on(running: true), .none, .on(running: true), .cantTell(.notListed), .cantTell(.unknownApp)])
        #expect(FirstRun.summary([]) == "No cloud accounts found")
    }

    @Test func whatEachLineSays() {
        let list = MenuBarAllowList(entries: [oneDriveID: .allowed, googleID: .notAllowed, "com.example.dropbox": .allowed])
        let clouds = FirstRun.clouds(snapshot, list: list, appOf: appOf, isRunning: { _ in true })
        #expect(clouds.map(FirstRun.iconLine) == [
            "Menu bar icons allowed, one per account",
            "No menu bar icon",
            "Menu bar icon turned off",
            "Menu bar icon allowed",
            "Can’t identify the app syncing this folder",
        ])
        #expect(FirstRun.iconAdvice(clouds) == "You can hide the menu bar icons for OneDrive and Dropbox (beta) under Allow in the Menu Bar. Hiding them doesn’t stop syncing.")
        // One app with one icon: "icon" and "it".
        let googleOnly = FirstRun.clouds(Snapshot.only(snapshot, [.googleDrive]), list: MenuBarAllowList(entries: [:]))
        #expect(FirstRun.iconAdvice(googleOnly) == "You can hide the menu bar icon for Google Drive under Allow in the Menu Bar. Hiding it doesn’t stop syncing.")
        // A beta app Velum can name but that isn't running.
        let quiet = FirstRun.clouds(snapshot, list: list, appOf: appOf, isRunning: { _ in false })
        #expect(FirstRun.iconLine(quiet[3]) == "Menu bar icon allowed · app isn’t running")
    }

    @Test func adviceWhenNothingIsOnOrVelumCantTell() {
        let off = MenuBarAllowList(entries: [oneDriveID: .notAllowed, googleID: .notAllowed])
        let oneAndGoogle = Snapshot.only(snapshot, [.oneDrive, .iCloud, .googleDrive])
        let allOff = FirstRun.clouds(oneAndGoogle, list: off)
        #expect(allOff.map(FirstRun.iconLine) == ["Menu bar icons turned off", "No menu bar icon", "Menu bar icon turned off"])
        #expect(FirstRun.iconAdvice(allOff) == "Menu bar icons are turned off for the apps above.")
        let unsure = FirstRun.clouds(oneAndGoogle, list: .unreadable)
        #expect(unsure.map(FirstRun.iconLine) == ["Can’t read its menu bar setting", "No menu bar icon", "Can’t read its menu bar setting"])
        #expect(FirstRun.iconAdvice(unsure) == "Velum can’t tell whether OneDrive and Google Drive show a menu bar icon. If you see one, you can hide it under Allow in the Menu Bar.")
        let betaOnly = FirstRun.clouds(Snapshot.only(snapshot, [.cloudStorage]), list: MenuBarAllowList(entries: [:]), appOf: appOf)
        #expect(FirstRun.iconLine(betaOnly[0]) == "Can’t tell whether this app has a menu bar icon")
        #expect(FirstRun.iconAdvice(betaOnly) == "Velum can’t tell whether Dropbox (beta) and AcmeSync (beta) show a menu bar icon. If you see one, you can hide it under Allow in the Menu Bar.")
        let iCloudOnly = FirstRun.clouds(Snapshot.only(snapshot, [.iCloud]), list: off)
        #expect(FirstRun.iconAdvice(iCloudOnly) == "None of these has a menu bar icon of its own.")
        #expect(FirstRun.iconAdvice([]) == "Sign in to OneDrive, iCloud Drive or Google Drive, and Velum finds it.")
    }

    @Test func aStoppedServiceIsListedAsNotRunning() {
        var stopped = Snapshot()
        stopped.providers = [ProviderStatus(id: .oneDrive, clientRunning: false), ProviderStatus(id: .googleDrive, clientRunning: false)]
        let clouds = FirstRun.clouds(stopped, list: MenuBarAllowList(entries: [oneDriveID: .allowed, googleID: .notAllowed]))
        #expect(clouds == [FoundCloud(name: "OneDrive", count: nil, icon: .on(running: false), notRunning: true),
                           FoundCloud(name: "Google Drive", count: nil, icon: .off, notRunning: true)])
        #expect(clouds.map(FirstRun.iconLine) == ["Menu bar icons allowed · app isn’t running", "App isn’t running"])
        #expect(FirstRun.summary(clouds) == "OneDrive · Google Drive")
        // The advice goes by the switch: still allowed, though the app isn't running now.
        #expect(FirstRun.iconAdvice(clouds) == "You can hide the menu bar icons for OneDrive under Allow in the Menu Bar. Hiding them doesn’t stop syncing.")
    }

    @Test func dumpSaysWhereItStandsAndWhatItRead() {
        let d = defaults()
        let lines = FirstRun.dumpLines(Snapshot.only(snapshot, [.oneDrive, .iCloud]), list: MenuBarAllowList(entries: [oneDriveID: .notAllowed]),
                                       defaults: d, ownBundleID: "com.example.velum")
        #expect(lines == ["First run: not shown (••• → Setup…) · clouds: OneDrive: 2 accounts · iCloud Drive",
                          "Menu bar icons: OneDrive: Menu bar icons turned off · iCloud Drive: No menu bar icon · Velum: menu bar icon allowed"])
        FirstRun.markDone(d)
        #expect(FirstRun.dumpLines(Snapshot(), list: .unreadable, defaults: d) == [
            "First run: done · clouds: No cloud accounts found", "Menu bar icons: the Allow in the Menu Bar list can’t be read"])
    }
}

private extension Snapshot {
    /// The snapshot with only these services.
    static func only(_ s: Snapshot, _ ids: [ProviderID]) -> Snapshot {
        var copy = s
        copy.providers = s.providers.filter { ids.contains($0.id) }
        copy.accounts = s.accounts.filter { ids.contains($0.provider) }
        return copy
    }
}
