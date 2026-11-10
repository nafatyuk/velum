import AppKit
import SwiftUI

/// Velum's own alert, shown under its menu bar icon when macOS won't let it post notifications (macOS
/// only allows that for apps signed with an Apple-issued certificate). Same Liquid Glass material as the
/// panel; fades after a few seconds, stays while hovered, and opens the panel when clicked. The idea
/// follows Crisp's on-screen banner (github.com/didriksg/Crisp, MIT).
@MainActor
final class Banner {
    private var panel: NSPanel?
    private var host: NSHostingView<BannerView>?
    private var hideWork: DispatchWorkItem?
    private let visibleFor: TimeInterval = 8

    /// The menu bar icon's window frame, to anchor under.
    var anchor: () -> NSRect? = { nil }
    var onClick: (() -> Void)?

    func show(title: String, body: String, isProblem: Bool) {
        let view = BannerView(title: title, message: body, isProblem: isProblem,
                              onClick: { [weak self] in self?.hide(); self?.onClick?() },
                              onHover: { [weak self] hovering in hovering ? self?.cancelHide() : self?.scheduleHide() })
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let host {
            host.rootView = view
        } else {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            let host = NSHostingView(rootView: view)
            glass.contentView = host
            panel.contentView = glass
            self.host = host
        }
        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if let anchor = anchor(), let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let top = screen.frame.maxY - screen.visibleFrame.maxY > 1 ? screen.visibleFrame.maxY - 6 : anchor.minY - 6
            var x = anchor.midX - size.width / 2
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            panel.setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height),
                           display: true)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    func hide() {
        cancelHide()
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    private func scheduleHide() {
        cancelHide()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }
}

struct BannerView: View {
    let title: String
    let message: String
    let isProblem: Bool
    let onClick: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isProblem ? Color.orange : Color.green)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 300)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
        .onHover(perform: onHover)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
