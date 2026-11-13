import SwiftUI

// "What the Status Means" (A4): the panel's own legend, shown in place of the accounts (a drill-in, like
// Control Center's expanded modules), opened from the ••• menu or the ⓘ in the header. Back, or Esc, returns.
// Its sections follow Codex's three blocks, as plain headings in one column (Fable's ruling): the icons and
// lights, where each status comes from and how old it may be, then Recent and the notes. Only the services
// on this Mac are explained; with none, all of them are.

struct LegendView: View {
    @ObservedObject var store: Store
    let back: () -> Void

    // Heights as laid out, so the legend scrolls under its pinned header only when the screen is too short.
    private let headerHeight = State(initialValue: CGFloat(0))
    private let contentHeight = State(initialValue: CGFloat(0))

    private var services: [ProviderID] {
        let present = store.snapshot.providers.map(\.id)
        return present.isEmpty ? ProviderID.allCases : present
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                InsetSeparator()
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { headerHeight.wrappedValue = $0 }
            let room = store.maxPanelHeight - headerHeight.wrappedValue
            let content = sections
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight.wrappedValue = $0 }
            if contentHeight.wrappedValue > room, room > 120 {
                ScrollView(.vertical) { content }
                    .frame(height: room)
            } else {
                content
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 4) {
            CircleIconButton(systemName: "chevron.left", help: "Back") { back() }
            Text("What the Status Means")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Icons and lights")
            ForEach(Self.states, id: \.text) { row in
                StateLine(badge: row.badge, platter: row.platter, text: row.text)
            }
            footnote("The menu bar shows the worst state of any account.")
            InsetSeparator().padding(.top, 8)
            heading("Sources and age")
            ForEach(Self.sourceLines(for: services), id: \.self) { line in bullet(line) }
            footnote(Self.oldRule)
            InsetSeparator().padding(.top, 8)
            heading("Recent and notes")
            ForEach(Self.notesLines(for: services), id: \.self) { line in bullet(line) }
                .padding(.bottom, 2)
            bullet(HistoryLine.legend(waitMinutes: max(1, Int(UploadTracker.stuckAfter / 60))))   // A6: the strip
        }
        .padding(.bottom, 10)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 4)
    }

    private func bullet(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 3)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.top, 4)
    }

    // MARK: The words, kept out of the view so tests can read them

    struct StateRow {
        let badge: SyncState      // the menu bar icon drawn for this state
        let platter: SyncState    // the row's circle
        let text: String
    }

    /// One row per menu bar badge, with the panel's circle for the same state. The plain cloud has two:
    /// evidence, and can't tell (no badge of its own; the summary and the row say so).
    static let states = [
        StateRow(badge: .ok, platter: .ok, text: "Nothing needs you. Shown only when Velum has evidence."),
        StateRow(badge: .unknown, platter: .unknown, text: "Velum can’t tell. The account’s row says why."),
        StateRow(badge: .syncing, platter: .syncing, text: "Syncing."),
        StateRow(badge: .paused, platter: .paused, text: "Paused."),
        StateRow(badge: .offline, platter: .offline, text: "Offline or not syncing."),
        StateRow(badge: .error, platter: .error, text: "A problem needs you (yellow: a warning)."),
        StateRow(badge: .notRunning, platter: .notRunning, text: "A sync app isn’t running."),
    ]

    /// When a report counts as old, in minutes, from the same numbers the merge uses.
    static func oldAfter(_ every: TimeInterval) -> Int { Int((every + ProviderReport.grace) / 60) }

    static let oldRule = "An old report is never green. The lid line never uses reports: only live file tracking, its coverage, running apps and live queues."

    static func sourceLines(for services: [ProviderID]) -> [String] {
        var lines = ["macOS, live: files waiting, uploading or failing, in every service. Only this decides the lid line."]
        for service in services {
            switch service {
            case .oneDrive:
                lines.append("OneDrive: its own icon text when you’ve turned that on (live); otherwise its report, written about every hour while this Mac is awake. Old after \(oldAfter(OneDriveProvider.reportEvery)) minutes.")
            case .iCloud:
                lines.append("iCloud: a status check Velum runs every \(Int(ICloudProvider.checkInterval / 60)) minutes. Old after \(oldAfter(ICloudProvider.checkInterval)) minutes.")
            case .googleDrive:
                lines.append("Google Drive: its own queue and pause, live. If Velum can’t read the queue, the row says so.")
            }
        }
        return lines
    }

    static func notesLines(for services: [ProviderID]) -> [String] {
        var lines: [String] = []
        let partial = services.filter { $0 != .oneDrive }.map(\.name)
        if services.contains(.oneDrive) {
            lines.append(partial.isEmpty ? "Recent: OneDrive’s own history."
                         : "Recent: OneDrive’s own history. For \(CompatibilityText.list(partial)), only uploads Velum saw finish while it was running.")
        } else if !partial.isEmpty {
            lines.append("Recent: only uploads Velum saw finish while it was running.")
        }
        if services.contains(.googleDrive) {
            lines.append("Google Drive storage is shared with Gmail and Photos. Orange when almost full (at least 90% used and under 10 GB free) or full (under 100 MB free).")
        }
        if services.contains(.iCloud) {
            lines.append("iCloud storage turns orange when it’s full. “Desktop & Documents included”: iCloud also syncs those folders, and Velum watches them.")
        }
        if services.contains(.googleDrive) || services.contains(.iCloud) {
            lines.append("Storage notes don’t change a row’s light.")
        }
        return lines
    }
}

/// One row of the legend's first block: the menu bar icon for a state, the panel's circle for it, and what
/// it means. VoiceOver reads only the words.
private struct StateLine: View {
    let badge: SyncState
    let platter: SyncState
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: StatusIcon.image(for: badge))
                .renderingMode(.template)
                .foregroundStyle(.primary)
                .frame(width: 24, height: 18)
                .accessibilityHidden(true)
            StatePlatter(state: platter)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
