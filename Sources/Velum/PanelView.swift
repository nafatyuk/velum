import SwiftUI
import UniformTypeIdentifiers

// Liquid Glass notes: the panel sits on NSGlassEffectView (see AppDelegate), so the glass material
// comes from macOS itself. Content sits directly on that glass (no cards, no opaque
// fills), separators are inset hairlines, hover highlights are concentric with the panel's corners,
// and the one prominent action uses the system glass button style.
//
// The Command Line Tools SDK ships SwiftUI's @State as a macro without its compiler plugin, so views
// hold the plain State struct (`State(initialValue:)`) and read/write `.wrappedValue` instead.

struct PanelActions {
    var openFolder: @MainActor (AccountConfig) -> Void
    var openURL: @MainActor (URL) -> Void
    var reveal: @MainActor (Activity) -> Void
    var copyPath: @MainActor (AccountConfig) -> Void
    var startOneDrive: @MainActor () -> Void
    var restartOneDrive: @MainActor () -> Void
    var quitOneDrive: @MainActor () -> Void
    var openMenuBarSettings: @MainActor () -> Void
    var enableExactStatus: @MainActor () -> Void
    var restartApp: @MainActor () -> Void
    var dismissExactStatusTip: @MainActor () -> Void
    var setLoginItem: @MainActor (Bool) -> Void
    var quitApp: @MainActor () -> Void
}

struct PanelView: View {
    @ObservedObject var store: Store
    let actions: PanelActions

    private let recentLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            InsetSeparator()
            if store.accounts.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(store.accounts) { account in
                        AccountRow(account: account, actions: actions)
                    }
                }
                .padding(.vertical, 5)
            }
            InsetSeparator()
            recent
            if showsBanner {
                InsetSeparator()
                banner
            }
        }
        .frame(width: 340)
        .containerShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text("OneDrive")
                    .font(.headline)
                Text(store.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            CircleIconButton(systemName: "arrow.clockwise", help: "Refresh") { store.refresh(force: true) }
            Menu {
                Toggle("Open at Login", isOn: Binding(
                    get: { store.loginItemEnabled },
                    set: { actions.setLoginItem($0) }
                ))
                Divider()
                if !store.snapshot.axTrusted {
                    Button("Show OneDrive’s Exact Status…") { actions.enableExactStatus() }
                }
                Button("Show OneDrive’s Own Icons…") { actions.openMenuBarSettings() }
                Divider()
                if store.snapshot.oneDriveRunning {
                    Button("Restart OneDrive") { actions.restartOneDrive() }
                    Button("Quit OneDrive") { actions.quitOneDrive() }
                } else {
                    Button("Start OneDrive") { actions.startOneDrive() }
                }
                Divider()
                Button("Quit Velum") { actions.quitApp() }
            } label: {
                CircleIconLabel(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.snapshot.oneDriveRunning ? "No synced OneDrive accounts found" : "OneDrive isn’t running")
                .font(.body.weight(.medium))
            Text("Accounts show up here once OneDrive is signed in and syncing.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Recent activity, both accounts merged

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 3)
            if store.activity.isEmpty {
                Text("Nothing synced recently")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                ForEach(store.activity.prefix(recentLimit)) { item in
                    let account = store.account(for: item.accountKey)
                    ActivityRow(
                        item: item,
                        accountName: account?.name ?? item.accountKey,
                        showAccount: store.accounts.count > 1,
                        folder: folderText(item, account?.config)
                    ) { actions.reveal(item) }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func folderText(_ item: Activity, _ config: AccountConfig?) -> String {
        guard let config, let relative = config.relativePath(of: item.path) else { return item.path }
        let parent = (relative as NSString).deletingLastPathComponent
        return parent.isEmpty ? "In the top of \(config.folder.lastPathComponent)" : "In \(parent)"
    }

    // MARK: Banner

    private var showsBanner: Bool {
        // The Accessibility tip only appears after the user asks for it from the ••• menu: it helps only
        // while OneDrive's own icons exist, so it shouldn't nag everyone.
        !store.snapshot.oneDriveRunning
            || (store.exactStatusRequested && !store.snapshot.axTrusted && !store.exactStatusTipDismissed)
    }

    @ViewBuilder private var banner: some View {
        if !store.snapshot.oneDriveRunning {
            BannerRow(symbol: "exclamationmark.icloud",
                      text: "OneDrive isn’t running, so nothing is syncing.",
                      button: "Start",
                      action: actions.startOneDrive)
        } else {
            BannerRow(symbol: "text.viewfinder",
                      text: "Switch on Velum in Accessibility, then restart it.",
                      button: "Restart",
                      action: actions.restartApp,
                      dismiss: actions.dismissExactStatusTip)
        }
    }
}

// MARK: - Rows

struct AccountRow: View {
    let account: AccountStatus
    let actions: PanelActions
    private let hover = State(initialValue: false)

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatePlatter(state: account.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name)
                    .font(.body.weight(.semibold))
                Text(account.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !account.detail.isEmpty {
                    Text(account.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                CircleIconButton(systemName: "folder", help: "Open in Finder") { actions.openFolder(account.config) }
                CircleIconButton(systemName: "globe", help: "View online") { actions.openURL(account.config.webURL) }
                Menu {
                    Button("Open in Finder") { actions.openFolder(account.config) }
                    Button("View Online") { actions.openURL(account.config.webURL) }
                    if let url = account.config.recycleBinURL {
                        Button("Recycle Bin") { actions.openURL(url) }
                    }
                    if let url = account.config.storageURL {
                        Button("Manage Storage") { actions.openURL(url) }
                    }
                    Divider()
                    Button("Copy Folder Path") { actions.copyPath(account.config) }
                } label: {
                    CircleIconLabel(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More for \(account.name)")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, 6)
        .background(HoverHighlight(isOn: hover.wrappedValue))
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .onTapGesture { actions.openFolder(account.config) }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(account.name), \(account.headline)")
    }
}

struct ActivityRow: View {
    let item: Activity
    let accountName: String
    let showAccount: Bool
    let folder: String
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(nsImage: FileIcons.icon(forName: item.name))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .opacity(item.isGone ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.body)
                        .foregroundStyle(item.isGone ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(HoverHighlight(isOn: hover.wrappedValue))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .padding(.horizontal, 6)
        .help(item.isGone ? "\(folder) (opens the nearest folder that still exists)" : "\(folder) (click to show in Finder)")
    }

    private var subtitle: String {
        var parts = [item.verb]
        if showAccount { parts.append(accountName) }
        parts.append(RelTime.string(item.date))
        if let app = item.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }
}

struct BannerRow: View {
    let symbol: String
    let text: String
    let button: String
    let action: () -> Void
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(button, action: action)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Hide this tip (it stays in the ••• menu)")
                .accessibilityLabel("Hide tip")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Pieces

/// Colored status circle, in the style of Control Center's module glyphs.
struct StatePlatter: View {
    let state: SyncState

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .symbolEffect(.rotate, options: .repeat(.continuous), isActive: state == .syncing)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color.gradient))
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch state {
        case .ok: "checkmark"
        case .unknown: "questionmark"
        case .syncing: "arrow.triangle.2.circlepath"
        case .paused: "pause.fill"
        case .offline: "wifi.slash"
        case .warning, .error: "exclamationmark"
        case .notRunning: "xmark"
        }
    }

    private var color: Color {
        switch state {
        case .ok: .green
        case .unknown: .gray
        case .syncing: .blue
        case .paused: .orange
        case .offline: .gray
        case .warning: .yellow
        case .error: .red
        case .notRunning: .gray
        }
    }
}

/// Hover fill whose corners stay concentric with the panel's rounded corners.
struct HoverHighlight: View {
    let isOn: Bool

    var body: some View {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(8)), isUniform: true)
            .fill(Color.primary.opacity(isOn ? 0.08 : 0))
    }
}

struct InsetSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 14)
    }
}

struct CircleIconLabel: View {
    let systemName: String
    var hovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
            .contentShape(Circle())
    }
}

struct CircleIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            CircleIconLabel(systemName: systemName, hovering: hover.wrappedValue)
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Type icons by file extension. Never touches the file itself, so cloud-only files stay cloud-only.
@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String) -> NSImage {
        let ext = (name as NSString).pathExtension.lowercased()
        if let image = cache[ext] { return image }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}
