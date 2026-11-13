import AppKit
import SwiftUI

// S1, a guided first run: the welcome card in a hotel room. What Velum found, the one switch you'll want
// (other apps' menu bar icons), where Velum's own light is, Open at Login and how alerts arrive.
//
// It shows in the panel, in place of the accounts like the legend, the first time Velum ever runs, and again
// from ••• → Setup…. It never nags: no alert, no badge, and the panel opens by itself only once, on that
// first launch. "Done" ends it for good, and so does closing the panel (Fable's ruling), except when its own
// Open Menu Bar Settings closed it: then it shows once more at the next opening, to see the switches again.
//
// Which vendor icons are in the menu bar comes from macOS's own "Allow in the Menu Bar" list (System
// Settings → Menu Bar), which Control Center keeps as `TrackedApplications` in the current host's
// `com.apple.controlcenter.systemmenubaritems` preferences: JSON, one entry per app, with `isAllowed`.
// Velum only reads it; it needs no permission. Checked on macOS 27.3, November 13, 2026:
// - status items are no longer windows of their own apps (Velum's own item has no window at all), so
//   `CGWindowListCopyWindowInfo` can't tell, by owner name or otherwise;
// - Accessibility can't either: an app that was already running when its icon was switched off keeps its
//   menu extras in Accessibility, so they would read as shown;
// - an app with no entry has never been switched: its icon is allowed, macOS's default (Velum's own icon
//   has no entry here, and shows).
// When the list can't be read or isn't in that shape, the answer is "can't tell", never a guess.

// MARK: When it shows

enum FirstRun {
    /// Set by "Done" or by closing the panel on it. From then on the first run shows only from ••• → Setup….
    static let doneKey = "firstRunDone"
    /// The next panel opening shows the first run: set at Velum's very first launch, and after its own Open
    /// Menu Bar Settings.
    static let pendingKey = "firstRunPending"
    /// Written at every install's first launch since Velum's first commit (`LoginItem.enableOnFirstLaunch`), so
    /// its absence means this is the very first launch.
    static let installedKey = "loginItemConfigured"

    /// What a launch does with the first run, from Velum's own defaults only.
    struct Launch: Equatable {
        var pending: Bool
        /// Open the panel by itself, once: only at the launch that starts the first run.
        var openPanel: Bool
    }

    /// Only a true first launch starts the first run. An install that has run before (it wrote
    /// `loginItemConfigured`) never gets it by itself; it is in ••• → Setup….
    static func launch(installedBefore: Bool, done: Bool, pending: Bool) -> Launch {
        if done { return Launch(pending: false, openPanel: false) }
        if pending { return Launch(pending: true, openPanel: false) }   // not finished last time: no second opening
        return installedBefore ? Launch(pending: false, openPanel: false) : Launch(pending: true, openPanel: true)
    }

    /// Called once at launch, before `LoginItem.enableOnFirstLaunch` writes `loginItemConfigured`. True when
    /// the panel should open by itself now.
    @discardableResult
    static func noteLaunch(_ defaults: UserDefaults = .standard) -> Bool {
        let result = launch(installedBefore: defaults.object(forKey: installedKey) != nil,
                            done: defaults.bool(forKey: doneKey), pending: defaults.bool(forKey: pendingKey))
        if result.pending, !defaults.bool(forKey: pendingKey) { defaults.set(true, forKey: pendingKey) }
        return result.openPanel
    }

    /// The panel opens on the first run.
    static func isPending(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingKey)
    }

    static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doneKey)
        defaults.removeObject(forKey: pendingKey)
    }

    /// Set by the first run's own Open Menu Bar Settings, which closes the panel on its way to System Settings.
    @MainActor static var wentToSettings = false

    /// The panel closed while showing the first run. Any close counts as done (Fable), except one caused by its
    /// own Open Menu Bar Settings: then it shows once more at the next opening, its switches read afresh.
    @MainActor
    static func panelClosed(_ defaults: UserDefaults = .standard) {
        let settings = wentToSettings
        wentToSettings = false
        if settings { defaults.set(true, forKey: pendingKey) } else { markDone(defaults) }
    }
}

// MARK: Which vendor icons are in the menu bar

/// macOS's "Allow in the Menu Bar" list, as read. Velum never writes it.
struct MenuBarAllowList: Equatable {
    enum Entry: Equatable { case allowed, notAllowed, unreadable }
    /// Bundle ID → the switch. nil: the list couldn't be read, or isn't in the shape Velum knows.
    var entries: [String: Entry]?

    static let domain = "com.apple.controlcenter.systemmenubaritems"
    static let key = "TrackedApplications"
    static let unreadable = MenuBarAllowList(entries: nil)

    /// Reads the list for this user and this Mac. Read-only: no permission, nothing written.
    static func read() -> MenuBarAllowList {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        guard let data = value as? Data else { return .unreadable }
        return MenuBarAllowList(entries: parse(data))
    }

    /// `{"<bundle ID>": {"rawBundleId": "…", "lastKnownLocalizedName": "…", "isAllowed": true}, …}`. Anything
    /// else gives nil. An entry without a true or false `isAllowed` is unreadable, never a guess.
    static func parse(_ data: Data) -> [String: Entry]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var entries: [String: Entry] = [:]
        for (key, value) in object {
            guard let app = value as? [String: Any] else { return nil }
            let id = (app["rawBundleId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            // JSONSerialization gives NSNumber for both booleans and numbers; only a real boolean counts.
            if let flag = app["isAllowed"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() {
                entries[id] = flag.boolValue ? .allowed : .notAllowed
            } else {
                entries[id] = .unreadable
            }
        }
        // Entries, but not one readable switch: the shape has changed.
        if !entries.isEmpty, !entries.values.contains(where: { $0 != .unreadable }) { return nil }
        return entries
    }
}

/// One cloud app's own menu bar icon.
enum VendorIcon: Equatable {
    /// The service draws no icon (iCloud Drive is part of macOS).
    case none
    /// Allowed in the menu bar. `running`: whether the app runs now (nil: Velum doesn't know).
    case on(running: Bool?)
    /// Switched off in System Settings → Menu Bar.
    case off
    case cantTell(CantTell)

    enum CantTell: Equatable {
        /// Velum couldn't read macOS's list.
        case listUnreadable
        /// The app's entry has no switch Velum can read.
        case entryUnreadable
        /// No entry, and Velum doesn't know whether this app draws an icon at all (the beta tier's apps).
        case notListed
        /// Velum can't tell which app syncs the folder.
        case unknownApp
    }

    /// The icon state for an app, from the list. `drawsIcon`: Velum knows this app puts an icon in the menu
    /// bar (OneDrive and Google Drive were checked), so no entry means macOS's default, allowed.
    static func of(bundleID: String?, drawsIcon: Bool, list: MenuBarAllowList, running: Bool?) -> VendorIcon {
        guard let bundleID else { return .cantTell(.unknownApp) }
        guard let entries = list.entries else { return .cantTell(.listUnreadable) }
        switch entries[bundleID] {
        case .allowed?: return .on(running: running)
        case .notAllowed?: return .off
        case .unreadable?: return .cantTell(.entryUnreadable)
        case nil: return drawsIcon ? .on(running: running) : .cantTell(.notListed)
        }
    }

    /// Switched on in the menu bar, whether or not the app runs now.
    var isOn: Bool { if case .on = self { true } else { false } }
    var isCantTell: Bool { if case .cantTell = self { true } else { false } }
}

/// One cloud the first run lists.
struct FoundCloud: Equatable {
    let name: String           // "OneDrive", "iCloud Drive", "Dropbox (beta)"
    let count: String?         // "2 accounts", "1 folder"; nil for iCloud Drive (one per Mac)
    let icon: VendorIcon
    let notRunning: Bool
}

extension FirstRun {
    /// The clouds in the snapshot, in the panel's order. `appOf` names the app behind a beta folder, and
    /// `isRunning` says whether that app runs.
    static func clouds(_ snapshot: Snapshot, list: MenuBarAllowList,
                       appOf: (URL) -> String? = { GenericProvider.identify($0).app?.bundleID },
                       isRunning: (String) -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
        -> [FoundCloud] {
        func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var found: [FoundCloud] = []
        for provider in snapshot.providers {
            let accounts = snapshot.accounts.filter { $0.provider == provider.id }
            guard !accounts.isEmpty || provider.isStopped else { continue }
            switch provider.id {
            case .oneDrive, .googleDrive:
                found.append(FoundCloud(name: provider.id.name, count: count(accounts.count, "account", "accounts"),
                                        icon: .of(bundleID: provider.id.clientBundleID, drawsIcon: true, list: list,
                                                  running: provider.clientRunning),
                                        notRunning: provider.isStopped))
            case .iCloud:
                found.append(FoundCloud(name: "iCloud Drive", count: nil, icon: .none, notRunning: false))
            case .cloudStorage:
                // One line per app, in the order its folders appear; folders of one app share it.
                var seen: [String] = []
                for account in accounts where !seen.contains(account.config.fallbackName) {
                    let client = account.config.fallbackName
                    seen.append(client)
                    let folders = accounts.filter { $0.config.fallbackName == client }
                    let bundleID = appOf(account.config.folder)
                    found.append(FoundCloud(name: "\(client) (beta)", count: count(folders.count, "folder", "folders"),
                                            icon: .of(bundleID: bundleID, drawsIcon: false, list: list, running: bundleID.map(isRunning)),
                                            notRunning: false))
                }
            }
        }
        return found
    }

    /// "OneDrive: 2 accounts · iCloud Drive · Google Drive: 1 account · Dropbox (beta)": the found clouds in one line.
    static func summary(_ clouds: [FoundCloud]) -> String {
        guard !clouds.isEmpty else { return "No cloud accounts found" }
        return clouds.map { cloud in
            guard let count = cloud.count, !cloud.name.hasSuffix("(beta)") || count != "1 folder" else { return cloud.name }
            return "\(cloud.name): \(count)"
        }.joined(separator: " · ")
    }

    /// OneDrive draws one icon per account.
    private static func severalIcons(_ cloud: FoundCloud) -> Bool {
        cloud.name == ProviderID.oneDrive.name && cloud.count != "1 account"
    }

    /// The line under a cloud's name: its own menu bar icon. "Allowed" is the setting's own word: it says
    /// nothing about whether the icon can be seen right now (Codex's wording, Fable's ruling).
    static func iconLine(_ cloud: FoundCloud) -> String {
        let several = severalIcons(cloud)
        switch cloud.icon {
        case .on(let running) where cloud.notRunning || running == false:
            return several ? "Menu bar icons allowed · app isn’t running" : "Menu bar icon allowed · app isn’t running"
        case _ where cloud.notRunning: return "App isn’t running"
        case .none: return "No menu bar icon"
        case .on: return several ? "Menu bar icons allowed, one per account" : "Menu bar icon allowed"
        case .off: return several ? "Menu bar icons turned off" : "Menu bar icon turned off"
        case .cantTell(let why):
            switch why {
            case .listUnreadable, .entryUnreadable: return "Can’t read its menu bar setting"
            case .notListed: return "Can’t tell whether this app has a menu bar icon"
            case .unknownApp: return "Can’t identify the app syncing this folder"
            }
        }
    }

    /// The sentence above Open Menu Bar Settings. It goes by the switch, not by whether the app runs now.
    static func iconAdvice(_ clouds: [FoundCloud]) -> String {
        let on = clouds.filter(\.icon.isOn)
        let unsure = clouds.filter(\.icon.isCantTell).map(\.name)
        if !on.isEmpty {
            let one = on.count == 1 && !severalIcons(on[0])
            return "You can hide the menu bar \(one ? "icon" : "icons") for \(CompatibilityText.list(on.map(\.name))) under Allow in the Menu Bar. Hiding \(one ? "it" : "them") doesn’t stop syncing."
        }
        if !unsure.isEmpty {
            return "Velum can’t tell whether \(CompatibilityText.list(unsure)) \(unsure.count == 1 ? "shows" : "show") a menu bar icon. If you see one, you can hide it under Allow in the Menu Bar."
        }
        if clouds.isEmpty { return "Sign in to OneDrive, iCloud Drive or Google Drive, and Velum finds it." }
        if clouds.allSatisfy({ $0.icon == .none }) { return "None of these has a menu bar icon of its own." }
        return "Menu bar icons are turned off for the apps above."
    }

    /// Velum's own entry in the list: switched off, the panel can't be opened again once it closes.
    static func ownIconOff(_ list: MenuBarAllowList, bundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        guard let bundleID else { return false }
        return list.entries?[bundleID] == .notAllowed
    }
}

// MARK: The view

/// Seams for `--render-first-run --sample`: a made-up list, so a render never shows this Mac's settings.
@MainActor
enum FirstRunSources {
    static var allowList: () -> MenuBarAllowList = MenuBarAllowList.read
    static var appOf: (URL) -> String? = { GenericProvider.identify($0).app?.bundleID }
    static var ownBundleID: String? = Bundle.main.bundleIdentifier
    /// For `--render-first-run` only: a glass button leaves an offscreen render (`cacheDisplay`) entirely blank,
    /// so renders draw bordered stand-ins in the same places.
    static var plainButtons = false
    /// For renders only: a changed snapshot (`--stopped`, `--no-clouds`).
    static var adjust: (Snapshot) -> Snapshot = { $0 }
}

struct FirstRunView: View {
    @ObservedObject var store: Store
    let actions: PanelActions

    // Heights as laid out, so the middle scrolls between the pinned header and footer only when the screen is
    // too short.
    private let headerHeight = State(initialValue: CGFloat(0))
    private let footerHeight = State(initialValue: CGFloat(0))
    private let contentHeight = State(initialValue: CGFloat(0))

    var body: some View {
        let list = FirstRunSources.allowList()
        let clouds = FirstRun.clouds(FirstRunSources.adjust(store.snapshot), list: list, appOf: FirstRunSources.appOf)
        let ownOff = FirstRun.ownIconOff(list, bundleID: FirstRunSources.ownBundleID)
        // One prominent button (Fable): Open Menu Bar Settings while there is something to switch, Done otherwise.
        let settingsFirst = clouds.contains(where: \.icon.isOn) || ownOff
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                InsetSeparator()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight.wrappedValue = $0 }
            let room = store.maxPanelHeight - headerHeight.wrappedValue - footerHeight.wrappedValue
            let content = sections(clouds, ownOff: ownOff, settingsFirst: settingsFirst)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight.wrappedValue = $0 }
            if contentHeight.wrappedValue > room, room > 120 {
                ScrollView(.vertical) { content }
                    .frame(height: room)
            } else {
                content
            }
            // Pinned, so Done and the way back are always in reach (Codex).
            VStack(alignment: .leading, spacing: 0) {
                InsetSeparator()
                footer(prominent: !settingsFirst)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { footerHeight.wrappedValue = $0 }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Welcome to Velum")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("One icon for every cloud on this Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private func sections(_ clouds: [FoundCloud], ownOff: Bool, settingsFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Clouds Velum found")
            ForEach(clouds, id: \.name) { cloud in CloudLine(cloud: cloud) }
            if clouds.isEmpty {
                Text("None yet")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 3)
            }
            Text(FirstRun.iconAdvice(clouds))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 6)
            button("Open Menu Bar Settings", prominent: settingsFirst) {
                FirstRun.wentToSettings = true   // closing the panel on the way there isn't "done"
                actions.openMenuBarSettings()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)

            InsetSeparator()
            heading("Velum’s icon")
            ownIcon(off: ownOff)

            InsetSeparator().padding(.top, 8)
            heading("Startup and alerts")
            SwitchLine(title: "Open at Login", isOn: Binding(get: { store.loginItemEnabled }, set: { actions.setLoginItem($0) }))
            SwitchLine(title: "Notify About Problems",
                       isOn: Binding(get: { store.notificationsEnabled }, set: { actions.setNotifications($0) }))
            Text(AppModel.notifier.systemAllowed ? FirstRunText.alertsSystem : FirstRunText.alertsBanner)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 2)
                .padding(.bottom, 10)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 3)
    }

    /// Glass on the panel; bordered stand-ins in renders, which glass leaves blank.
    @ViewBuilder private func button(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        switch (FirstRunSources.plainButtons, prominent) {
        case (true, true): Button(title, action: action).buttonStyle(.borderedProminent).controlSize(.small)
        case (true, false): Button(title, action: action).buttonStyle(.bordered).controlSize(.small)
        case (false, true): Button(title, action: action).buttonStyle(.glassProminent).controlSize(.small)
        case (false, false): Button(title, action: action).buttonStyle(.glass).controlSize(.small)
        }
    }

    private func ownIcon(off: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: StatusIcon.image(for: .ok))
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(width: 24, height: 18)
                    .accessibilityHidden(true)
                Text(FirstRunText.ownIcon)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if off {
                // The one orange thing here: with Velum's own icon off, the panel can't be reopened.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text(FirstRunText.ownIconOff)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func footer(prominent: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Find this again in ••• → Setup…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            button("Done", prominent: prominent, action: done)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "Done": for good. The panel goes back to the accounts.
    private func done() {
        FirstRun.markDone()
        store.showingFirstRun = false
    }
}

/// The words, kept out of the view so tests and the consultants can read them.
enum FirstRunText {
    static let ownIcon = "Velum is this cloud in the menu bar. If you can’t see it, macOS may have put it with the hidden icons: click « in the menu bar to show them. To move the cloud, hold ⌘ and drag it."
    static let ownIconOff = "Velum’s own icon is switched off in Menu Bar settings. Switch it on there to open this panel again."
    static let alertsBanner = "Alerts show as a banner under Velum’s icon. This copy of Velum isn’t signed for macOS notifications."
    static let alertsSystem = "Alerts come as macOS notifications."
}

/// A found cloud: its name and count, and its own icon underneath.
private struct CloudLine: View {
    let cloud: FoundCloud

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(cloud.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let count = cloud.count {
                    Text(count)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
            Text(FirstRun.iconLine(cloud))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A switch in the style of Control Center's rows: the title, then the switch at the trailing edge.
private struct SwitchLine: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.body)
            Spacer(minLength: 4)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Rendering, for checking without the real panel

extension FirstRun {
    /// `Velum --render-first-run out.png [--dark] [--sample <name>] [--icons on|mixed|off|own-off|unreadable|live]
    /// [--stopped] [--no-clouds]`. With `--sample`, made-up clouds and, unless `--icons live`, a made-up "Allow
    /// in the Menu Bar" list: safe to share. Without it, this Mac's clouds. A live list is printed too
    /// (read-only). Buttons are drawn bordered, not glass (`--glass-buttons` keeps glass, and the image comes
    /// out blank). `--stopped` shows OneDrive and Google Drive not running; `--no-clouds` shows none found.
    @MainActor
    static func prepareRender() {
        AppModel.store.showingFirstRun = true
        let args = CommandLine.arguments
        FirstRunSources.plainButtons = !args.contains("--glass-buttons")   // glass: the whole image comes out blank
        let stopped = args.contains("--stopped"), none = args.contains("--no-clouds")
        FirstRunSources.adjust = { snapshot in
            if none { return Snapshot() }
            var s = snapshot
            if stopped {
                s.providers = s.providers.map { $0.id.clientBundleID == nil ? $0 : ProviderStatus(id: $0.id, clientRunning: false) }
            }
            return s
        }
        let mode = args.firstIndex(of: "--icons").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? (args.contains("--sample") ? "on" : "live")
        guard mode != "live" else {
            let list = MenuBarAllowList.read()
            print("Allow in the Menu Bar (\(MenuBarAllowList.domain), current host): " + (list.entries == nil ? "can’t read it" : "\(list.entries!.count) apps listed"))
            for (name, id) in [("OneDrive", ProviderID.oneDrive.clientBundleID), ("Google Drive", ProviderID.googleDrive.clientBundleID),
                               ("Velum", Bundle.main.bundleIdentifier)] {
                guard let id else { continue }
                let entry = list.entries?[id].map { "\($0)" } ?? (list.entries == nil ? "unknown" : "not listed (macOS’s default: allowed)")
                print("  \(name) [\(id)]: \(entry) · running: \(!NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty)")
            }
            return
        }
        let sample: [String: MenuBarAllowList.Entry] = switch mode {
        case "off": [oneDriveBundleID: .notAllowed, "com.google.drivefs": .notAllowed]
        case "mixed": [oneDriveBundleID: .allowed, "com.google.drivefs": .notAllowed]
        case "own-off": [oneDriveBundleID: .allowed, "com.example.velum": .notAllowed]
        default: [oneDriveBundleID: .allowed]
        }
        let list = mode == "unreadable" ? MenuBarAllowList.unreadable : MenuBarAllowList(entries: sample)
        FirstRunSources.allowList = { list }
        FirstRunSources.appOf = { $0.lastPathComponent == "Dropbox" ? "com.example.dropbox" : nil }
        FirstRunSources.ownBundleID = "com.example.velum"
    }

    /// For `Velum --dump`: where the first run stands, the clouds it would list, and each one's menu bar
    /// setting as read from macOS's list (read-only).
    static func dumpLines(_ snapshot: Snapshot, list: MenuBarAllowList = .read(), defaults: UserDefaults = .standard,
                          ownBundleID: String? = Bundle.main.bundleIdentifier) -> [String] {
        let state = isPending(defaults) ? "shows at the next panel opening"
            : defaults.bool(forKey: doneKey) ? "done" : "not shown (••• → Setup…)"
        let clouds = Self.clouds(snapshot, list: list)
        let icons = clouds.map { "\($0.name): \(iconLine($0))" }
            + [list.entries == nil ? "the Allow in the Menu Bar list can’t be read" : ownIconOff(list, bundleID: ownBundleID) ? "Velum: menu bar icon turned off" : "Velum: menu bar icon allowed"]
        return ["First run: \(state) · clouds: \(summary(clouds))", "Menu bar icons: " + icons.joined(separator: " · ")]
    }
}
