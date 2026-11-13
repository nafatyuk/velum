import Combine
import SwiftUI

/// "Not in the cloud yet" (card A3): the files the lid line only counts, by name. A file shows once its
/// latest change has waited past the stuck threshold (10 minutes; see `UploadTracker.stuckAfter`), or at
/// once when its upload fails. Failing files come first, then the oldest. Five rows, then "Show N more".
/// Clicking a row shows the file in Finder. Velum observes, so there's no retry or "force upload" button.
/// Look and wording chosen by Codex and the Fable consultant (see the A3 card's hand-off).
struct StuckFilesView: View {
    @ObservedObject var store: Store
    let actions: PanelActions
    private let expanded = State(initialValue: false)

    var body: some View {
        let list = store.snapshot.stuck
        VStack(alignment: .leading, spacing: 0) {
            if list.total > 0 { section(list) }
        }
        // Collapse "Show more" when the panel closes (it resigns key) and when five or fewer are left.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            expanded.wrappedValue = false
        }
        .onChange(of: list.files.count > StuckWording.shownAtFirst) { _, more in
            if !more { expanded.wrappedValue = false }
        }
    }

    @ViewBuilder private func section(_ list: PendingList) -> some View {
        let layout = StuckWording.layout(list, expanded: expanded.wrappedValue)
        VStack(alignment: .leading, spacing: 0) {
            heading(list.total)
            // Ages move on while the panel is open, even when nothing else changes.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 0) {
                    ForEach(layout.rows) { file in
                        row(file, now: context.date)
                    }
                }
            }
            if layout.hidden > 0 || expanded.wrappedValue && list.files.count > StuckWording.shownAtFirst {
                moreButton(hidden: layout.hidden)
            }
            if layout.unlisted > 0 {
                Text("and \(layout.unlisted) more not listed")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, StuckWording.textInset)
                    .padding(.vertical, 3)
            }
        }
        .padding(.bottom, 6)
        InsetSeparator()
    }

    private func heading(_ total: Int) -> some View {
        HStack(spacing: 6) {
            Text("Not in the cloud yet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(StuckWording.files(total))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Not in the cloud yet, \(StuckWording.files(total))")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ file: PendingFile, now: Date) -> some View {
        let account = store.account(for: file.account)
        // A stopped app is the evidence-backed cause; macOS's own reason then blames "the server or network".
        let stopped = store.snapshot.providers.first { $0.id == account?.provider && $0.isStopped }?.id.name
        return StuckFileRow(
            file: file,
            subtitle: StuckWording.subtitle(file, account: store.accounts.count > 1 ? account?.name : nil,
                                            stopped: stopped, now: now),
            help: StuckWording.help(file, folder: account?.config.location(of: file.path), now: now),
            spoken: StuckWording.spoken(file, account: account.map(store.spokenName) ?? file.account,
                                        folder: account?.config.location(of: file.path), stopped: stopped, now: now)
        ) {
            actions.reveal(Activity(accountKey: file.account, path: file.path, name: file.name, kind: 0,
                                    date: file.since, app: nil))
        }
    }

    private func moreButton(hidden: Int) -> some View {
        let open = expanded.wrappedValue
        return StuckMoreButton(title: open ? "Show fewer" : "Show \(hidden) more",
                               spoken: open ? "Show fewer files" : "Show \(hidden) more \(hidden == 1 ? "file" : "files")") {
            expanded.wrappedValue.toggle()
        }
    }
}

/// One file, in the shape of Recent's rows: its type icon, its name, then what's holding it up. A failing
/// file's reason, as macOS words it, gets a line of its own.
struct StuckFileRow: View {
    let file: PendingFile
    let subtitle: String
    let help: String
    let spoken: String
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            // A failing row runs to three lines or more: its icon stays beside the name instead of centring.
            HStack(alignment: file.isFailing ? .top : .center, spacing: 10) {
                Image(nsImage: FileIcons.icon(forName: file.name))
                    .resizable()
                    .frame(width: 26, height: 26)
                    .padding(.top, file.isFailing ? 4 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(file.isFailing ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                    if case .failed(let reason) = file.status {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityHint("Shows the file in Finder")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Show 2 more" / "Show fewer", lined up with the file names above it.
struct StuckMoreButton: View {
    let title: String
    let spoken: String
    let action: () -> Void
    private let hover = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, StuckWording.textInset - 6)
            .padding(.vertical, 4)
            .background(HoverHighlight(isOn: hover.wrappedValue))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .padding(.horizontal, 6)
        .accessibilityLabel(spoken)
    }
}

/// The section's wording and layout, kept apart from the views so tests can pin them.
enum StuckWording {
    static let shownAtFirst = 5
    /// Where a row's file name starts: the row's insets (6 + 8), the 26-pt icon and its 10-pt gap.
    static let textInset: CGFloat = 50

    /// The rows to draw, how many listed files the "Show N more" button holds back, and how many qualified
    /// beyond the listing's cap (shown only once expanded).
    static func layout(_ list: PendingList, expanded: Bool) -> (rows: [PendingFile], hidden: Int, unlisted: Int) {
        let showAll = expanded && list.files.count > shownAtFirst
        let rows = showAll ? list.files : Array(list.files.prefix(shownAtFirst))
        let unlisted = max(0, list.total - list.files.count)
        return (rows, list.files.count - rows.count, showAll || list.files.count <= shownAtFirst ? unlisted : 0)
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    /// "Waiting 12 min · Personal", "Uploading · changed 2 hr ago", "Can’t upload · Personal". The account
    /// goes last (it's what truncates), and only when there's more than one account. A failing file whose
    /// service app is stopped (`stopped`, the service's name) says so: "Can’t upload · OneDrive isn’t running".
    static func subtitle(_ file: PendingFile, account: String?, stopped: String? = nil, now: Date) -> String {
        let state = switch file.status {
        case .waiting: "Waiting \(waited(file.since, now: now))"
        case .uploading: "Uploading · changed \(RelTime.string(file.since, now: now))"
        case .failed: stopped.map { "Can’t upload · \($0) isn’t running" } ?? "Can’t upload"
        }
        return [state, account].compactMap { $0 }.joined(separator: " · ")
    }

    /// "12 min", "2 hr", "3 days", or "since Nov 3" after a week: how long the latest change has waited.
    static func waited(_ since: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(since))
        if s < 60 { return "under 1 min" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86400 { return "\(Int(s / 3600)) hr" }
        let days = Int(s / 86400)
        if days < 7 { return days == 1 ? "1 day" : "\(days) days" }
        return "since " + since.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Hover text: "In Documents/Taxes · changed at 2:14 PM (click to show in Finder)".
    static func help(_ file: PendingFile, folder: String?, now: Date) -> String {
        let when = Calendar.current.isDate(file.since, inSameDayAs: now)
            ? "at \(RelTime.clock(file.since))"
            : file.since.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "\(folder ?? file.path) · changed \(when) (click to show in Finder)"
    }

    /// VoiceOver says everything the row truncates or hides: "Report.docx, waiting 2 hours, Personal, In
    /// Documents/Taxes".
    static func spoken(_ file: PendingFile, account: String, folder: String?, stopped: String? = nil, now: Date) -> String {
        let age = spokenAge(file.since, now: now)
        let state = switch file.status {
        case .waiting: "waiting \(age)"
        case .uploading: "uploading, changed \(age) ago"
        case .failed(let reason):
            (stopped.map { "can’t upload, \($0) isn’t running. " } ?? "can’t upload. ")
                + (reason.hasSuffix(".") ? String(reason.dropLast()) : reason)
        }
        return [file.name, state, account, folder].compactMap { $0 }.joined(separator: ", ")
    }

    private static func spokenAge(_ since: Date, now: Date) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: max(60, now.timeIntervalSince(since))) ?? ""
    }
}
