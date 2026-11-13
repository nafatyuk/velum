import AppKit
import Combine
import ServiceManagement
import SwiftUI

// The menu bar shell follows Crisp's approach (github.com/didriksg/Crisp, MIT): a plain NSStatusItem
// plus a non-activating NSPanel on NSGlassEffectView, the material Control Center panels use, anchored
// under the icon. On macOS 27 the item opens through NSStatusItemExpandedInterfaceDelegate, so the
// system lights the icon and tracks clicks and keyboard navigation like a native menu.

/// The panel window. Escape closes it, like a menu.
final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel?
    private var host: NSHostingView<PanelView>?
    private var clickMonitor: Any?
    private var isPanelShown = false
    private var hasShownOnce = false
    private var subscriptions = Set<AnyCancellable>()
    private let banner = Banner()

    private let cornerRadius: CGFloat = 16

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            NSApp.terminate(nil)   // already running
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusIcon.image(for: .ok)
            button.imagePosition = .imageOnly
            // Clicks on macOS 27 arrive through the expanded interface session below; this action
            // still serves VoiceOver/accessibility presses.
            button.target = self
            button.action = #selector(togglePanel)
        }
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { statusItem.expandedInterfaceDelegate = self }
        #endif

        let store = AppModel.store
        AppModel.panelCloser = { [weak self] in self?.closePanel() }
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &subscriptions)
        // Content height changes (a banner appearing, an account row changing) re-fit the panel.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitPanel() } }
            .store(in: &subscriptions)
        store.start()

        let notifier = AppModel.notifier
        notifier.start()
        notifier.onOpen = { [weak self] in self?.showPanel() }
        banner.anchor = { [weak self] in self?.statusItem.button?.window?.frame }
        banner.onClick = { [weak self] in self?.showPanel() }
        notifier.fallback = { [weak self] title, body, isProblem in
            guard let self, !self.isPanelShown else { return }   // already looking at the panel
            self.banner.show(title: title, body: body, isProblem: isProblem)
        }
        store.onRefresh = { snapshot in notifier.update(snapshot, enabled: store.notificationsEnabled) }
        if store.notificationsEnabled { notifier.requestPermission() }

        LoginItem.enableOnFirstLaunch()
        store.loginItemEnabled = LoginItem.isEnabled
        GoogleSignInStorage.install()   // the optional Google sign-in for storage; off until turned on per account
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let store = AppModel.store
        button.image = StatusIcon.image(for: store.overallState)
        button.toolTip = store.tooltip
        button.setAccessibilityLabel(store.accessibilitySummary)
    }

    @objc private func togglePanel() {
        isPanelShown ? closePanel() : showPanel()
    }

    // MARK: Panel

    private func makePanel() -> MenuPanel {
        let p = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                          styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                          backing: .buffered, defer: false)
        // isFloatingPanel sets its own level, so it must come before .popUpMenu.
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        p.onCancel = { [weak self] in self?.closePanel() }

        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        let host = NSHostingView(rootView: PanelView(store: AppModel.store, actions: AppModel.actions))
        glass.contentView = host
        p.contentView = glass
        self.host = host
        return p
    }

    private func showPanel() {
        let p = panel ?? makePanel()
        panel = p
        let store = AppModel.store
        store.refresh()
        store.loginItemEnabled = LoginItem.isEnabled

        fitPanel(force: true)
        // Only the first open fades in, so the glass's one-time materialize plays under the fade.
        p.alphaValue = hasShownOnce ? 1 : 0
        p.orderFrontRegardless()
        p.makeKey()
        if !hasShownOnce {
            hasShownOnce = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
        isPanelShown = true

        if clickMonitor == nil {
            // Clicks in other apps close the panel, like a menu. Clicks on our own icon are handled by
            // the expanded interface session instead.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, self.isPanelShown else { return }
                    if panel.frame.contains(NSEvent.mouseLocation) { return }
                    self.closePanel()
                }
            }
        }
    }

    private func closePanel() {
        guard let p = panel, isPanelShown else { return }
        isPanelShown = false
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) { statusItem.expandedInterfaceSession?.cancel() }
        #endif
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard !self.isPanelShown else { return }
                p.orderOut(nil)
                p.alphaValue = 1
            }
        })
    }

    /// Sizes the panel to its content and pins it under the menu bar icon.
    private func fitPanel(force: Bool = false) {
        guard let p = panel, let host, isPanelShown || force else { return }
        if let visible = (statusItem.button?.window?.screen ?? NSScreen.main)?.visibleFrame {
            let cap = (visible.height - 12).rounded()
            if AppModel.store.maxPanelHeight != cap { AppModel.store.maxPanelHeight = cap }
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }

        guard let buttonWindow = statusItem.button?.window else { return }
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen ?? NSScreen.main
        var top = anchor.minY - 1
        // macOS 27's status item window reaches a few points past the menu bar, so anchor to the
        // bar's own bottom edge (Crisp measured this against the native panels).
        if let screen, screen.frame.maxY - screen.visibleFrame.maxY > 1 {
            top = screen.visibleFrame.maxY - 1
        }
        var x = anchor.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        let frame = NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
        if p.frame != frame { p.setFrame(frame, display: true) }
    }
}

#if compiler(>=6.4)
@available(macOS 27.0, *)
extension AppDelegate: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        isPanelShown ? closePanel() : showPanel()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        closePanel()
    }
}
#endif

/// Shared state and the panel's actions.
@MainActor
enum AppModel {
    static let store = Store()
    static let notifier = Notifier()
    static var panelCloser: (() -> Void)?

    static func closePanel() {
        panelCloser?()
    }

    static let actions = PanelActions(
        openFolder: { config in
            closePanel()
            NSWorkspace.shared.open(config.folder)
        },
        openURL: { url in
            closePanel()
            NSWorkspace.shared.open(url)
        },
        reveal: { item in
            closePanel()
            OneDriveControl.reveal(item)
        },
        copyPath: { config in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(config.folder.path, forType: .string)
        },
        startClient: { provider in
            debugLog("action", "Start \(provider.name) (clicked in Velum)")
            if let id = provider.clientBundleID { ClientControl.launch(bundleID: id) }
            store.refresh(force: true)
        },
        restartClient: { provider in
            guard let id = provider.clientBundleID else { return }
            debugLog("action", "Restart \(provider.name) (clicked in Velum)")
            notifier.userStopped[provider] = Date()
            ClientControl.restart(bundleID: id) { store.refresh(force: true) }
            store.refresh(force: true)
        },
        quitClient: { provider in
            guard let id = provider.clientBundleID else { return }
            debugLog("action", "Quit \(provider.name) (clicked in Velum)")
            notifier.userStopped[provider] = Date()
            ClientControl.quit(bundleID: id)
            store.refresh(force: true)
        },
        openMenuBarSettings: {
            closePanel()
            OneDriveControl.openSystemSettings(.menuBar)
        },
        enableExactStatus: {
            closePanel()
            store.exactStatusRequested = true
            store.exactStatusTipDismissed = false
            LiveStatus.requestTrust()
            OneDriveControl.openSystemSettings(.accessibility)
        },
        restartApp: {
            OneDriveControl.relaunchSelf()
        },
        dismissExactStatusTip: {
            store.exactStatusTipDismissed = true
        },
        setDebugLogging: { on in
            store.debugLogging = on
        },
        openDebugLog: {
            closePanel()
            let file = DebugLog.shared.file
            if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.open(file) }
            else { NSWorkspace.shared.open(file.deletingLastPathComponent().deletingLastPathComponent()) }
        },
        setNotifications: { on in
            store.notificationsEnabled = on
            if on { notifier.requestPermission() }
        },
        setLoginItem: { on in
            LoginItem.setEnabled(on)
            store.loginItemEnabled = LoginItem.isEnabled
        },
        quitApp: {
            NSApp.terminate(nil)
        }
    )
}

/// The single menu bar icon: a cloud, plus a small cut-out badge when something needs attention.
/// Drawn as a template image so macOS tints it for the Liquid Glass menu bar in light and dark.
@MainActor
enum StatusIcon {
    private static var cache: [SyncState: NSImage] = [:]

    static func image(for state: SyncState) -> NSImage {
        if let cached = cache[state] { return cached }

        let badgeSymbol: String? = switch state {
        case .ok, .unknown: nil
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.fill"
        case .offline: "minus"
        case .warning, .error: "exclamationmark"
        case .notRunning: "xmark"
        }

        let cloud = NSImage(systemSymbolName: "cloud", accessibilityDescription: "Velum")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let size = NSSize(width: 24, height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            let c = cloud.size
            let shift: CGFloat = badgeSymbol == nil ? 0 : -1.5
            cloud.draw(in: NSRect(x: (rect.width - c.width) / 2 + shift, y: (rect.height - c.height) / 2,
                                  width: c.width, height: c.height))

            if let badgeSymbol, let ctx = NSGraphicsContext.current?.cgContext,
               let glyph = NSImage(systemSymbolName: badgeSymbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 6.5, weight: .heavy)) {
                let d: CGFloat = 10.5
                let circle = NSRect(x: rect.maxX - d - 0.5, y: 0.5, width: d, height: d)
                ctx.setBlendMode(.clear)                       // gap between cloud and badge
                ctx.fillEllipse(in: circle.insetBy(dx: -1.5, dy: -1.5))
                ctx.setBlendMode(.normal)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillEllipse(in: circle)
                let g = glyph.size
                glyph.draw(in: NSRect(x: circle.midX - g.width / 2, y: circle.midY - g.height / 2,
                                      width: g.width, height: g.height),
                           from: .zero, operation: .destinationOut, fraction: 1)   // glyph cut out of the badge
            }
            return true
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Velum: login item change failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Turns "Open at Login" on once, the first time the app runs. After that it's the user's toggle.
    static func enableOnFirstLaunch() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { setEnabled(true) }
    }
}

enum SettingsPane {
    case menuBar, accessibility
}

@MainActor
enum ClientControl {
    /// Starts a sync service's app in the background.
    static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
    }
}

extension ClientControl {
    /// Asks every running copy of the app to quit, as the Quit menu item would.
    static func quit(bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            app.terminate()
        }
    }

    /// Quits the app, waits up to ~10 s for it to finish, and starts it again in the background.
    static func restart(bundleID: String, completion: @escaping @MainActor () -> Void) {
        quit(bundleID: bundleID)
        Task { @MainActor in
            for _ in 0..<50 {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                if running.allSatisfy(\.isTerminated) { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            launch(bundleID: bundleID)
            completion()
        }
    }
}

@MainActor
enum OneDriveControl {

    /// Shows the file in Finder; for deleted or moved items, opens the nearest folder that still exists.
    static func reveal(_ item: Activity) {
        let fm = FileManager.default
        if !item.isGone, fm.fileExists(atPath: item.path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            return
        }
        var dir = URL(fileURLWithPath: item.path).deletingLastPathComponent()
        while dir.path.count > 1, !fm.fileExists(atPath: dir.path) {
            dir = dir.deletingLastPathComponent()
        }
        NSWorkspace.shared.open(dir)
    }

    /// Starts a fresh copy of Velum once this one has quit.
    static func relaunchSelf() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openSystemSettings(_ pane: SettingsPane) {
        let address = switch pane {
        case .menuBar: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
