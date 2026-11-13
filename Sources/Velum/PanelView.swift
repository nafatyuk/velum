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
    var startClient: @MainActor (ProviderID) -> Void
    var restartClient: @MainActor (ProviderID) -> Void
    var quitClient: @MainActor (ProviderID) -> Void
    var openMenuBarSettings: @MainActor () -> Void
    var enableExactStatus: @MainActor () -> Void
    var restartApp: @MainActor () -> Void
    var dismissExactStatusTip: @MainActor () -> Void
    var setDebugLogging: @MainActor (Bool) -> Void
    var openDebugLog: @MainActor () -> Void
    var setNotifications: @MainActor (Bool) -> Void
    var setLoginItem: @MainActor (Bool) -> Void
    var quitApp: @MainActor () -> Void
    var setGoogleSignIn: @MainActor (_ email: String, _ on: Bool) -> Void = { GoogleSignInStorage.set($0, on: $1) }
    var exportDiagnostics: @MainActor () -> Void = { DiagnosticsReport.exportFromMenu() }   // card S2
}

struct PanelView: View {
    @ObservedObject var store: Store
    let actions: PanelActions

    private let recentLimit = 6
    // Heights measured as laid out, to cap the panel at the screen's height (any number of accounts).
    private let topHeight = State(initialValue: CGFloat(0))
    private let bodyHeight = State(initialValue: CGFloat(0))

    var body: some View {
        Group {
            if store.showingLegend {
                LegendView(store: store) { store.showingLegend = false }
            } else {
                main
            }
        }
        .frame(width: 340)
        .containerShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                InsetSeparator()
                LidRow(verdict: store.lidVerdict)
                InsetSeparator()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { topHeight.wrappedValue = $0 }
            scrollingBody
            if showsBanner {
                InsetSeparator()
                banner
            }
        }
    }

    /// The accounts and Recent. They scroll, under a pinned header and lid line, only when the whole panel
    /// would be taller than the screen.
    @ViewBuilder private var scrollingBody: some View {
        let room = store.maxPanelHeight - topHeight.wrappedValue - (showsBanner ? 64 : 0)
        let content = VStack(alignment: .leading, spacing: 0) {
            StuckFilesView(store: store, actions: actions)   // A3 "Not in the cloud yet": only while files qualify
            accountsSection
            InsetSeparator()
            recent
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { bodyHeight.wrappedValue = $0 }
        if bodyHeight.wrappedValue > room, room > 120 {
            ScrollView(.vertical) { content }
                .frame(height: room)
        } else {
            content
        }
    }

    /// A heading per service with its accounts under it, in a fixed order (never sorted by trouble), even
    /// when only one service is left, so services coming and going never rearrange the panel. Service-wide
    /// problems (not running, storage full) sit at the heading's trailing edge. With many accounts, healthy
    /// rows shrink to one line; any row that needs attention keeps its full layout.
    @ViewBuilder private var accountsSection: some View {
        if store.snapshot.providers.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(store.snapshot.providers, id: \.id) { provider in
                    let accounts = store.accounts.filter { $0.provider == provider.id }
                    if !accounts.isEmpty || provider.isStopped {
                        ServiceHeading(provider: provider, accounts: accounts) { actions.startClient(provider.id) }
                        ForEach(accounts) { account in
                            AccountRow(account: account, spokenName: store.spokenName(account),
                                       compact: store.compactRows && account.state == .ok && !account.notesNeedAttention
                                           && account.reason == nil,
                                       actions: actions)
                        }
                    }
                }
            }
            .padding(.bottom, 5)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 2) {
            VStack(alignment: .leading, spacing: 1) {
                Text(store.title)
                    .font(.headline)
                Text(store.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            CircleIconButton(systemName: "info.circle", help: "What the Status Means") { store.showingLegend = true }
            CircleIconButton(systemName: "arrow.clockwise", help: "Refresh") { store.refresh(force: true) }
            Menu {
                Button("What the Status Means…") { store.showingLegend = true }
                Toggle("Notify About Problems", isOn: Binding(
                    get: { store.notificationsEnabled },
                    set: { actions.setNotifications($0) }
                ))
                Toggle("Open at Login", isOn: Binding(
                    get: { store.loginItemEnabled },
                    set: { actions.setLoginItem($0) }
                ))
                OtherCloudFoldersToggle(store: store)   // C3: only while the tier has folders, or is switched off
                Button("Menu Bar Settings…") { actions.openMenuBarSettings() }
                Divider()
                Toggle("Debug Logging", isOn: Binding(
                    get: { store.debugLogging },
                    set: { actions.setDebugLogging($0) }
                ))
                if store.debugLogging || FileManager.default.fileExists(atPath: DebugLog.shared.file.path) {
                    Button("Open Debug Log") { actions.openDebugLog() }
                }
                Button("Export Diagnostics…") { actions.exportDiagnostics() }
                if store.snapshot.oneDrive != nil, !store.snapshot.axTrusted {
                    Button("Show OneDrive’s Exact Status…") { actions.enableExactStatus() }
                }
                // Start, Restart and Quit for every service that has an app of its own, in panel order.
                ForEach(store.snapshot.providers.filter { $0.id.clientBundleID != nil }, id: \.id) { provider in
                    Divider()
                    if provider.clientRunning == true {
                        Button("Restart \(provider.id.name)") { actions.restartClient(provider.id) }
                        Button("Quit \(provider.id.name)") { actions.quitClient(provider.id) }
                    } else {
                        Button("Start \(provider.id.name)") { actions.startClient(provider.id) }
                    }
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
            Text("No cloud accounts found")
                .font(.body.weight(.medium))
            Text("OneDrive, iCloud Drive and Google Drive accounts show up here once they’re signed in and syncing. Other cloud folders show up too, in beta.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Recent activity, every account merged

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
                        folder: folderText(item, account?.config),
                        seenByVelum: account?.config.keepsOwnHistory == false
                    ) { actions.reveal(item) }
                }
            }
        }
        .padding(.bottom, 6)
    }

    private func folderText(_ item: Activity, _ config: AccountConfig?) -> String {
        config?.location(of: item.path) ?? item.path
    }

    // MARK: Banner

    private var showsBanner: Bool {
        // The Accessibility tip only appears after the user asks for it from the ••• menu: it helps only
        // while OneDrive's own icons exist, so it shouldn't nag everyone.
        store.snapshot.oneDrive != nil && store.exactStatusRequested && !store.snapshot.axTrusted
            && !store.exactStatusTipDismissed
    }

    /// A stopped service shows "Not running" and Start at its own heading; the banner is only the
    /// exact-status tip, after the user asks for it.
    private var banner: some View {
        BannerRow(symbol: "text.viewfinder",
                  text: "Switch on Velum in Accessibility, then restart it.",
                  button: "Restart",
                  action: actions.restartApp,
                  dismiss: actions.dismissExactStatusTip)
    }
}

// MARK: - Rows

struct AccountRow: View {
    let account: AccountStatus
    /// What VoiceOver calls it: "OneDrive, School" when several services share the panel.
    let spokenName: String
    /// One line (name and headline) for a healthy account when there are many.
    var compact = false
    let actions: PanelActions
    private let hover = State(initialValue: false)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .center, spacing: 10) {
                StatePlatter(state: account.state)
                top
                Spacer(minLength: 4)
                buttons
            }
            // The reason, notes and source run under the buttons to the row's trailing edge: the column
            // beside the buttons is too narrow for a reason (Codex). Indented to line up with the name.
            if !compact { lines.padding(.leading, 38).padding(.trailing, 8) }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, compact ? 3 : 6)
        .background(HoverHighlight(isOn: hover.wrappedValue))
        .contentShape(Rectangle())
        .onHover { hover.wrappedValue = $0 }
        .onTapGesture { actions.openFolder(account.config) }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(spokenName), \(account.headline)")
        .accessibilityValue(spokenDetails)
    }

    /// What VoiceOver reads after the name and headline: the reason, the notes and the source with its age,
    /// with "min" and "hr" spelled out.
    private var spokenDetails: String {
        Reasons.spoken([account.reason ?? "", account.notes, account.detail].filter { !$0.isEmpty }.joined(separator: ". "))
    }

    @ViewBuilder private var top: some View {
            if compact {
                // The headline goes when the name needs the room (the check mark already says it).
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        name.fixedSize()
                        Text(account.headline)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    name
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    name
                    Text(account.headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }

    /// Long names (Google accounts are email addresses) lose their middle, never their domain.
    private var name: some View {
        Text(account.name)
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(account.name)
    }

    /// Under the name and headline: why Velum can't tell (A4), the notes, then the source with its age.
    private var lines: some View {
            VStack(alignment: .leading, spacing: 1) {
                if let reason = account.reason {
                    // Never cut: the end of a reason is what would make the status known again.
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !account.notes.isEmpty {
                    Text(account.notes)
                        .font(.caption)
                        .foregroundStyle(account.notesNeedAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(account.notesHelp ?? "")
                }
                if !account.detail.isEmpty {
                    Text(account.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }

    private var buttons: some View {
            HStack(spacing: 0) {
                CircleIconButton(systemName: "folder", help: "Open in Finder") { actions.openFolder(account.config) }
                if let web = account.config.webURL { CircleIconButton(systemName: "globe", help: "View online") { actions.openURL(web) } }
                Menu {
                    Button("Open in Finder") { actions.openFolder(account.config) }
                    if let web = account.config.webURL { Button("View Online") { actions.openURL(web) } }
                    if let url = account.config.recycleBinURL {
                        Button(account.provider.deletedFilesLabel) { actions.openURL(url) }
                    }
                    if let url = account.config.storageURL {
                        Button(account.provider == .iCloud ? "iCloud Settings…" : "Manage Storage") { actions.openURL(url) }
                    }
                    GoogleSignInMenuItems(config: account.config, set: actions.setGoogleSignIn)
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
}

struct ActivityRow: View {
    let item: Activity
    let accountName: String
    let showAccount: Bool
    let folder: String
    /// Recorded by Velum itself (iCloud keeps no history Velum can read).
    var seenByVelum = false
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
        .help(helpText)
    }

    private var helpText: String {
        let base = item.isGone ? "\(folder) (opens the nearest folder that still exists)" : "\(folder) (click to show in Finder)"
        return seenByVelum ? base + ". Velum saw this upload finish while it was running." : base
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

/// A service's name over its accounts, in the style of the "Recent" heading. Service-wide trouble sits at
/// its trailing edge: OneDrive not running (with Start), iCloud storage full.
struct ServiceHeading: View {
    let provider: ProviderStatus
    let accounts: [AccountStatus]
    let start: () -> Void

    /// "3 accounts", "2 of 3 up to date" when some need attention, "1 up to date · 1 can’t tell" when the
    /// rest are only unknown (they don't need attention).
    private var count: String? {
        guard accounts.count > 1 else { return nil }
        let fine = accounts.filter { $0.state == .ok }.count
        let unsure = accounts.filter { $0.state == .unknown }.count
        if fine == accounts.count { return "\(accounts.count) accounts" }
        if fine + unsure == accounts.count { return "\(fine) up to date · \(unsure) can’t tell" }
        return "\(fine) of \(accounts.count) up to date"
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(provider.id.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if provider.isStopped {
                Text("Not running")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                Button("Start", action: start)
                    .buttonStyle(.glassProminent)
                    .controlSize(.mini)
                    .accessibilityLabel("Start \(provider.id.name)")
            } else if let trouble = provider.trouble {
                Text(trouble)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            } else if provider.id.isBeta {   // C3: a count of folders; beta is on each row
                Text(accounts.count == 1 ? "1 folder" : "\(accounts.count) folders").font(.subheadline).foregroundStyle(.tertiary)
            } else if let count {
                Text(count)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 2)
    }
}

/// "Is it safe to close the lid?" Answered from live upload tracking: every local change is in the cloud,
/// or it isn't, or Velum can't vouch for it.
struct LidRow: View {
    let verdict: LidVerdict

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    var title: String {
        switch verdict {
        case .safe: "Safe to close the lid"
        case .pending, .busy: "Wait before closing the lid"
        case .failing, .notRunning: "Not everything is in the cloud"
        case .unknown: "Can’t vouch for every change"
        }
    }

    var subtitle: String {
        switch verdict {
        case .safe: "Every change in the watched cloud folders is in the cloud."
        case .pending(let n): "\(files(n)) still on the way up."
        case .busy(let name): "\(name) is still syncing changes."
        case .failing(let n): "\(files(n)) can’t upload. See the account below."
        case .notRunning(let name): "\(name) isn’t running, so new changes stay on this Mac."
        case .unknown(let reason): reason + "."
        }
    }

    private var symbol: String {
        switch verdict {
        case .safe: "laptopcomputer"
        case .pending, .busy: "arrow.up.circle.fill"
        case .failing, .notRunning: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch verdict {
        case .safe: .green
        case .pending, .busy: .blue
        case .failing, .notRunning: .orange
        case .unknown: .secondary
        }
    }
}

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
