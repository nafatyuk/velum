import AppKit
import Darwin
import SystemConfiguration

// Card S2: a diagnostics report that redacts itself, to attach to an issue. Two ways in, one report:
// `Velum --dump --redact` prints it, and ••• → Export Diagnostics… writes it to ~/Library/Logs/Velum (never a
// synced folder) and shows it in Finder. Velum never sends it anywhere. Decisions by the Codex and Fable
// consult (November 13, 2026):
// - the report is built field by field, so Velum's own labels never pass through the matcher. Only text Velum
//   doesn't word itself (reasons, notes, check details, failure reasons, log lines) is swept, and
//   over-redaction there is accepted: an organization called "Drive" takes "Drive" out of "Google Drive";
// - an account in the panel is "Account N" everywhere, its organization and folder names included; an address
//   or organization Velum can't tie to an account is "<email N>" or "<org N>";
// - every byte figure is <size>, every storage percentage <percent>;
// - the debug log's last 24 hours, at most 500 lines, from both of its files.

/// Replaces what identifies the user, the same way every time within one report: a name always gets the same
/// label. Text goes through `text` (Velum's own sentences, check details) or `foreign` (text from macOS or the
/// log, which may hold names Velum never knew); paths go through `path`.
final class Redactor {
    let home: String
    private var needles: [(text: String, label: String)] = []
    private var needlesSorted = true
    private var labels: [String: String] = [:]      // lowercased needle → its label
    private var files: [String: String] = [:]       // lowercased file name → "file-N.ext"
    private var emails: [String: String] = [:]      // lowercased address → "<email N>"
    private var orgs: [String: String] = [:]        // lowercased name → "<org N>"
    private var ids: [String: String] = [:]
    private var roots: [String] = []
    private var accounts = 0
    private var regexes: [String: NSRegularExpression] = [:]

    /// Velum's and the services' own words, never anyone's: kept even when an account is called that.
    static let ownWords: Set<String> = ["personal", "business", "onedrive", "icloud", "icloud drive", "google drive",
                                        "my drive", "desktop", "documents", "sharedlibraries", "shared libraries"]
    /// Velum's own files and the services' files it names; the file-name sweep leaves them.
    static let ownFiles: Set<String> = ["velum.log", "velum.1.log", "syncdiagnostics.log", "uxdatabase.db", "info.plist"]
    /// Shorter names aren't swept from free text (a file called "a" would take every "a"); fields still are.
    static let shortest = 3

    init(home: String) {
        let h = Self.nfc(home)
        self.home = h.count > 1 && h.hasSuffix("/") ? String(h.dropLast()) : h
    }

    // MARK: What to replace

    /// Labels an account "Account 1", "Account 2"… in the order they come (the panel's accounts first, then
    /// accounts only the debug log names) and returns its label.
    @discardableResult
    func account(_ names: [String]) -> String {
        accounts += 1
        let label = "Account \(accounts)"
        for name in names { add(name, as: label) }
        return label
    }

    func person(_ names: [String]) {
        for name in names { add(name, as: "<user>") }
    }

    func computer(_ name: String) {
        add(name, as: "<computer>")
    }

    /// A Google account's numeric ID (DriveFS names its folders after them).
    @discardableResult
    func id(_ value: String) -> String {
        if let label = ids[value] { return label }
        let label = "<id \(ids.count + 1)>"
        ids[value] = label
        add(value, as: label)
        return label
    }

    /// "Budget 2027.xlsx" → "file-1.xlsx", the same label each time it comes up.
    @discardableResult
    func file(_ raw: String) -> String {
        let name = Self.nfc(raw).trimmingCharacters(in: .whitespaces)
        let key = name.lowercased()
        if Self.ownFiles.contains(key) || name.isEmpty { return name }
        if let label = files[key] { return label }
        let ext = (name as NSString).pathExtension
        let keep = !ext.isEmpty && ext.count <= 8 && ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let label = "file-\(files.count + 1)" + (keep ? "." + ext : "")
        files[key] = label
        add(name, as: label)
        return label
    }

    /// A synced folder: paths inside it show as "<the folder>/…/file-1.docx".
    func root(_ path: String) {
        var p = Self.nfc(path)
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        if !p.isEmpty, !roots.contains(p) { roots.append(p) }
    }

    /// Learns names from the debug log's own shapes, so accounts since removed and files no longer pending are
    /// replaced too: "Northwind [OneDrive]: appeared", "…: 1 failing · first: Report.docx: …".
    func harvest(_ lines: [String]) {
        for raw in lines {
            let line = Self.nfc(raw)
            for pattern in Self.accountShapes {
                for groups in matches(pattern, in: line) { if let name = groups[1] { harvestAccount(name) } }
            }
            for pattern in Self.fileShapes {
                for groups in matches(pattern, in: line) { if let name = groups[1] { file(name) } }
            }
            for groups in matches(Self.quotedFile, in: line) { if let name = groups[1] { file(name) } }
        }
    }

    private func harvestAccount(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        let key = name.lowercased()
        guard name.count >= Self.shortest, name.count <= 120, labels[key] == nil, !Self.ownWords.contains(key),
              !ProviderID.allCases.contains(where: { $0.name.lowercased() == key }) else { return }
        account([name])
    }

    private func add(_ raw: String, as label: String) {
        let text = Self.nfc(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let key = text.lowercased()
        guard text.count >= Self.shortest, !Self.ownWords.contains(key), labels[key] == nil else { return }
        labels[key] = label
        needles.append((text, label))
        needlesSorted = false
    }

    // MARK: Replacing

    /// Text Velum words itself, with names, paths, addresses and figures in it.
    func text(_ s: String) -> String { sweep(s, foreign: false) }

    /// Text Velum didn't word: macOS's failure reasons, the debug log. Also replaces anything in curly quotes
    /// and any word with a file extension.
    func foreign(_ s: String) -> String { sweep(s, foreign: true) }

    /// "~/Library/CloudStorage/OneDrive-Account 2/…/file-3.pdf": the synced folder, never the folders inside it.
    func path(_ raw: String) -> String {
        let p = Self.nfc(raw)
        let lower = p.lowercased()
        let last = (p as NSString).lastPathComponent
        let root = roots.filter { lower == $0.lowercased() || lower.hasPrefix($0.lowercased() + "/") }.max { $0.count < $1.count }
        if let root { return lower == root.lowercased() ? shownRoot(root) : shownRoot(root) + "/…/" + file(last) }
        if lower == home.lowercased() { return "~" }
        if lower.hasPrefix(home.lowercased() + "/") { return "~/…/" + file(last) }
        return (p.hasPrefix("/") ? "/…/" : "…/") + file(last)
    }

    /// A synced folder as the report shows it: "~/Library/CloudStorage/GoogleDrive-Account 4".
    func shownRoot(_ path: String) -> String {
        let lower = path.lowercased(), h = home.lowercased()
        if lower == h { return "~" }
        guard lower.hasPrefix(h + "/") else { return sweep(path, foreign: false, paths: false) }
        let parts = path.dropFirst(home.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return "~/" + parts.map { sweep(String($0), foreign: false, paths: false) }.joined(separator: "/")
    }

    private enum Piece {
        case text(String)
        case done(String)
    }

    private func sweep(_ raw: String, foreign: Bool, paths: Bool = true) -> String {
        var pieces: [Piece] = [.text(Self.nfc(raw))]
        pieces = replace(pieces, Self.secret) { _, _ in "<token>" }
        pieces = replace(pieces, Self.url) { match, _ in Self.urlLabel(match) }
        if paths {
            // A synced folder, then the home folder, then anyone else's or a volume's: the folders inside go.
            for root in roots.sorted(by: { $0.count > $1.count }) {
                pieces = replace(pieces, NSRegularExpression.escapedPattern(for: root) + Self.pathEnd + Self.pathTail) { [self] _, groups in
                    shownRoot(root) + tail(groups[1])
                }
            }
            pieces = replace(pieces, NSRegularExpression.escapedPattern(for: home) + Self.pathEnd + Self.pathTail) { [self] _, groups in
                "~" + tail(groups[1])
            }
            pieces = replace(pieces, Self.otherHome) { [self] _, groups in
                (groups[1] == "Volumes" ? "/Volumes/<volume>" : "/Users/<user>") + tail(groups[2])
            }
        }
        pieces = replaceNeedles(pieces)
        pieces = replace(pieces, Self.email) { [self] match, _ in
            // "GoogleDrive-x@example.com": the folder's prefix stays, the address goes.
            let folder = match.lowercased().hasPrefix("googledrive-") ? String(match.prefix(GoogleDriveProvider.folderPrefix.count)) : ""
            let key = match.dropFirst(folder.count).lowercased()
            if let label = labels[key] ?? emails[key] { return folder + label }
            let label = "<email \(emails.count + 1)>"
            emails[key] = label
            return folder + label
        }
        pieces = replace(pieces, Self.cloudFolder) { [self] _, groups in
            let service = groups[1] ?? "", shared = groups[2] ?? ""
            let name = (groups[3] ?? "").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-")))
            guard !name.isEmpty, !Self.ownWords.contains(name.lowercased()) else { return nil }
            return "\(service)-\(shared)" + org(name)
        }
        pieces = replace(pieces, Self.longNumber) { [self] match, _ in id(match) }
        pieces = replace(pieces, Self.size) { _, _ in "<size>" }
        pieces = replace(pieces, Self.percent) { _, _ in "<percent>" }
        if foreign {
            pieces = replace(pieces, Self.quoted) { [self] match, _ in
                let inner = String(match.dropFirst().dropLast())
                return "“" + (Self.looksLikeFile(inner) ? file(inner) : "…") + "”"
            }
            pieces = replace(pieces, Self.fileWord) { [self] match, _ in
                Self.ownFiles.contains(match.lowercased()) ? nil : file(match)
            }
        }
        return pieces.map { piece in
            switch piece {
            case .text(let s), .done(let s): s
            }
        }.joined()
    }

    /// "/Plans/Q4/Report.docx" after a folder → "/…/file-2.docx"; nothing after it → "".
    private func tail(_ rest: String?) -> String {
        guard let rest, !rest.isEmpty else { return "" }
        return "/…/" + file((rest as NSString).lastPathComponent)
    }

    private func org(_ name: String) -> String {
        let key = name.lowercased()
        if let label = labels[key] { return label }
        if let label = orgs[key] { return label }
        let label = "<org \(orgs.count + 1)>"
        orgs[key] = label
        return label
    }

    /// Every known name, longest first, whole words only, any case.
    private func replaceNeedles(_ pieces: [Piece]) -> [Piece] {
        if !needlesSorted {
            needles.sort { $0.text.count > $1.text.count }
            needlesSorted = true
        }
        return pieces.flatMap { piece -> [Piece] in
            guard case .text(let s) = piece, !s.isEmpty else { return [piece] }
            var taken: [(range: Range<String.Index>, label: String)] = []
            for needle in needles {
                var start = s.startIndex
                while start < s.endIndex, let r = s.range(of: needle.text, options: .caseInsensitive, range: start..<s.endIndex) {
                    if Self.bounded(r, in: s, needle: needle.text), !taken.contains(where: { $0.range.overlaps(r) }) {
                        taken.append((r, needle.label))
                    }
                    start = s.index(after: r.lowerBound)
                }
            }
            return Self.split(s, taken.map { ($0.range, $0.label) })
        }
    }

    private func replace(_ pieces: [Piece], _ pattern: String, _ label: (String, [String?]) -> String?) -> [Piece] {
        guard let regex = regex(pattern) else { return pieces }
        return pieces.flatMap { piece -> [Piece] in
            guard case .text(let s) = piece, !s.isEmpty else { return [piece] }
            var found: [(Range<String.Index>, String)] = []
            for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let range = Range(m.range, in: s), !range.isEmpty else { continue }
                let groups = (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
                if let replacement = label(String(s[range]), groups) { found.append((range, replacement)) }
            }
            return Self.split(s, found)
        }
    }

    private static func split(_ s: String, _ found: [(Range<String.Index>, String)]) -> [Piece] {
        var out: [Piece] = []
        var cursor = s.startIndex
        for (range, label) in found.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) where range.lowerBound >= cursor {
            if cursor < range.lowerBound { out.append(.text(String(s[cursor..<range.lowerBound]))) }
            out.append(.done(label))
            cursor = range.upperBound
        }
        if cursor < s.endIndex { out.append(.text(String(s[cursor...]))) }
        return out
    }

    private func matches(_ pattern: String, in s: String) -> [[String?]] {
        guard let regex = regex(pattern) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
        }
    }

    private func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = regexes[pattern] { return cached }
        let made = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        regexes[pattern] = made
        return made
    }

    private static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// A whole-word match: no letter or digit runs into it on either side.
    private static func bounded(_ r: Range<String.Index>, in s: String, needle: String) -> Bool {
        if let first = needle.first, isWord(first), r.lowerBound > s.startIndex, isWord(s[s.index(before: r.lowerBound)]) { return false }
        if let last = needle.last, isWord(last), r.upperBound < s.endIndex, isWord(s[r.upperBound]) { return false }
        return true
    }

    static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    static func looksLikeFile(_ s: String) -> Bool {
        let ext = (s as NSString).pathExtension
        return !ext.isEmpty && ext.count <= 8 && ext.first?.isLetter == true && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// "<url at sharepoint.com>" for a service everyone knows; "<url>" for anything else, which may be an
    /// organization's own domain.
    static func urlLabel(_ url: String) -> String {
        guard let host = URL(string: url)?.host?.lowercased() else { return "<url>" }
        let known = ["sharepoint.com", "live.com", "office.com", "microsoft.com", "google.com", "googleapis.com",
                     "icloud.com", "apple.com", "github.com"]
        return known.first { host == $0 || host.hasSuffix("." + $0) }.map { "<url at \($0)>" } ?? "<url>"
    }

    // MARK: Shapes

    /// Sign-in tokens never get into a report Velum makes; these catch one that slipped into a log line anyway.
    static let secret = #"\bya29\.[A-Za-z0-9_\-.]+|\b1//[A-Za-z0-9_\-]{10,}|\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#
    static let url = #"\bhttps?://[^\s<>"“”]+"#
    /// A known folder ends at a slash, a space or punctuation: "/Users/test" isn't the start of "/Users/tester".
    static let pathEnd = #"(?=[/\s·,;:)“”"]|$)"#
    /// The folders after a known folder, up to the end of the line or a " · ".
    static let pathTail = #"((?:/[^/\n·“”"]*[^/\n·“”"\s])*)"#
    static let otherHome = #"/(Users|Volumes)/[^/\n·“”"]*[^/\n·“”"\s]((?:/[^/\n·“”"]*[^/\n·“”"\s])*)"#
    static let email = #"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.\p{L}{2,}"#
    /// "OneDrive-Northwind Traders", "OneDrive-SharedLibraries-Northwind", "GoogleDrive-<something not an address>".
    static let cloudFolder = #"\b(OneDrive|GoogleDrive)-(SharedLibraries-)?([^\s/,·()“”"<>]+(?: [^\s/,·()“”"<>]+)*)"#
    static let longNumber = #"(?<![\p{L}\p{N}])\p{N}{15,}(?![\p{L}\p{N}])"#
    static let size = #"(?<![\p{L}\p{N}.,])(?:\d+(?:[.,]\d+)?|Zero)[\s  ]?(?:bytes?|[KMGTPE]B|kB)(?![\p{L}\p{N}])"#
    static let percent = #"(?<![\p{L}\p{N}.,])\d+(?:[.,]\d+)?[\s ]?%(?=[\s ]+(?:full|used))"#
    static let quoted = #"“[^”\n]*”"#
    static let quotedFile = #"“([^”\n]+\.\p{L}[\p{L}\p{N}]{0,7})”"#
    static let fileWord = #"(?<![\p{L}\p{N}_.\-@/])[\p{L}\p{N}_\-]+(?:\.[\p{L}\p{N}_\-]+)*\.\p{L}[\p{L}\p{N}]{0,7}(?![\p{L}\p{N}_\-])"#
    /// Where the debug log names an account (DebugLog.changes, Notifier, the providers).
    static let accountShapes = [
        #"\[status\] (.+?) \[(?:OneDrive|iCloud|Google Drive)\]: (?:appeared|gone)"#,
        #"\[status\] (.+?): (?:ok|unknown|syncing|offline|paused|warning|notRunning|error) → "#,
        #"\[status\] (.+?): \d+ failing · first: "#,
        #"\[status\] (.+?): (?:watching every change again|Velum may have missed changes)"#,
        #"\[alert\] (.+?): (?:\d+ files? can’t upload|uploads are stuck|changes are stuck|resolved) · "#,
        #"\[alert\] (.+?) (?:was disconnected|isn’t syncing) · "#,
        #"\[alert\] .+? storage full · (.+?) · "#,
        #"\[google\] (.+?): Google Drive's queue "#,
        #"\[tracker\] googledrive:(.+?): "#,
    ]
    /// Where the debug log names a file: a failing upload's "<name>: <reason>".
    static let fileShapes = [
        #"\[status\] .+?: \d+ failing · first: (.+?): "#,
        #"\[alert\] .+?: \d+ files? can’t upload · (.+?): "#,
    ]
}

// MARK: - The report

/// What Velum read on the OneDrive account's hourly report file, for the report's evidence line.
enum OneDriveReportFile: Equatable {
    case missing
    case unreadable
    case read(Diagnostics)
}

/// The debug log's recent lines, oldest first.
struct DiagnosticsLog: Equatable {
    var lines: [String] = []
    /// How many lines the window held before the cap.
    var total = 0
    var window: TimeInterval = 86_400
    var limit = 500
}

/// Everything the report shows, gathered once. `DiagnosticsReport.render` reads nothing else, so tests can feed
/// it made-up input.
struct DiagnosticsInput {
    enum Origin { case app, terminal }

    var origin: Origin
    var now: Date
    var snapshot: Snapshot
    var transfers: [String: TransferInfo] = [:]

    // Velum and this Mac
    var velumVersion = "Velum (dev build)"
    var velumBuilt: Date?
    var runningSince: Date?
    var macOS = ""
    var model = ""
    var chip = ""
    var language = ""

    // Settings
    var notifications = true
    var openAtLogin = false
    var debugLogging = false
    var stuckAfter: TimeInterval = 600
    var stuckAfterOverridden = false
    var googleSignInAvailable = false
    /// Lowercased addresses whose optional Google sign-in is on.
    var googleSignInOn: Set<String> = []

    // Evidence read straight from disk: OneDrive's report per account, Google Drive's pause file.
    var oneDriveReports: [String: OneDriveReportFile] = [:]
    var googlePaused: Bool?

    // Only for redaction
    var home: String
    var userNames: [String] = []
    var computerName: String?
    var driveFSIDs: [String] = []

    var log = DiagnosticsLog()
}

enum DiagnosticsReport {
    /// Where exports go: next to the debug log, never a synced folder (Desktop and Documents can be in iCloud).
    static var folder: URL { DebugLog.shared.file.deletingLastPathComponent() }

    // MARK: Ways in

    /// ••• → Export Diagnostics…: writes the report and shows it in Finder, selected.
    @MainActor
    static func exportFromMenu() {
        AppModel.closePanel()
        let input = gather(snapshot: AppModel.store.snapshot, transfers: AppModel.store.transferSnapshot, origin: .app)
        do {
            let url = try write(render(input), in: folder, now: input.now)
            debugLog("action", "Export Diagnostics (clicked in Velum)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Velum couldn’t save the diagnostics report"
            alert.informativeText = "\(error.localizedDescription) Nothing was saved."
            alert.runModal()
        }
    }

    /// `Velum --dump --redact`: the same report, from a fresh look, printed.
    @MainActor
    static func printFromTerminal() {
        let (snapshot, transfers, _) = DebugDump.collectOnce()
        Swift.print(render(gather(snapshot: snapshot, transfers: transfers, origin: .terminal)), terminator: "")
    }

    static func fileName(_ now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Velum Diagnostics \(f.string(from: now)).txt"
    }

    /// Writes `text` as a new file in `folder` ("… 2.txt" when the name is taken) and returns where.
    static func write(_ text: String, in folder: URL, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = fileName(now)
        var url = folder.appending(path: base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: String(base.dropLast(4)) + " \(n).txt")
            n += 1
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    // MARK: Gathering, on this Mac

    @MainActor
    static func gather(snapshot: Snapshot, transfers: [String: TransferInfo], origin: DiagnosticsInput.Origin,
                       now: Date = Date()) -> DiagnosticsInput {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var input = DiagnosticsInput(origin: origin, now: now, snapshot: snapshot, transfers: transfers, home: home.path)
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            input.velumVersion = "Velum \(version)"
        }
        input.velumBuilt = Bundle.main.executableURL.flatMap { (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
        input.runningSince = origin == .app ? processStart() : nil
        input.macOS = ProcessInfo.processInfo.operatingSystemVersionString
        input.model = sysctlString("hw.model") ?? ""
        input.chip = sysctlString("machdep.cpu.brand_string") ?? ""
        input.language = [Locale.preferredLanguages.first, "format \(Locale.current.identifier)"].compactMap { $0 }.joined(separator: ", ")

        let defaults = UserDefaults.standard
        input.notifications = defaults.object(forKey: "notificationsEnabled") as? Bool ?? true
        input.openAtLogin = LoginItem.isEnabled
        input.debugLogging = DebugLog.shared.isEnabled
        input.stuckAfter = UploadTracker.stuckAfter
        input.stuckAfterOverridden = defaults.double(forKey: "stuckAfterSeconds") > 0
        input.googleSignInAvailable = GoogleOAuthClient.load() != nil
        input.googleSignInOn = Set((defaults.stringArray(forKey: GoogleSignInStorage.defaultsKey) ?? []).map { $0.lowercased() })

        for account in snapshot.accounts where account.provider == .oneDrive && !account.id.hasPrefix(OneDriveCompatibility.folderKeyPrefix) {
            let path = OneDriveFiles.diagnosticsPath(account.id)
            input.oneDriveReports[account.id] = !fm.fileExists(atPath: path) ? OneDriveReportFile.missing
                : OneDriveFiles.diagnostics(at: path).map { OneDriveReportFile.read($0) } ?? OneDriveReportFile.unreadable
        }
        let driveFS = home.appending(path: "Library/Application Support/Google/DriveFS", directoryHint: .isDirectory)
        if snapshot.providers.contains(where: { $0.id == .googleDrive }) {
            input.googlePaused = fm.fileExists(atPath: driveFS.appending(path: "user-paused").path)
        }
        input.driveFSIDs = ((try? fm.contentsOfDirectory(atPath: driveFS.path)) ?? [])
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }.sorted()
        input.userNames = [NSUserName(), NSFullUserName()] + NSFullUserName().split(separator: " ").map(String.init)
        input.computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        input.log = recentLog(in: DebugLog.shared.file.deletingLastPathComponent(), now: now)
        return input
    }

    /// The debug log's lines from the last `window`, oldest first, from the rotated file and the current one;
    /// the newest `limit` when there are more.
    static func recentLog(in directory: URL, now: Date, window: TimeInterval = 86_400, limit: Int = 500) -> DiagnosticsLog {
        var all: [String] = []
        for name in ["Velum.1.log", "Velum.log"] {
            guard let data = try? Data(contentsOf: directory.appending(path: name)) else { continue }
            all += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        let cutoff = now.addingTimeInterval(-window)
        var kept: [String] = []
        var keeping = false
        for line in all {
            // A line without a time of its own (a message with a line break) goes with the line before it.
            if let date = stamp(line) { keeping = date >= cutoff }
            if keeping { kept.append(line) }
        }
        return DiagnosticsLog(lines: Array(kept.suffix(limit)), total: kept.count, window: window, limit: limit)
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func stamp(_ line: String) -> Date? {
        line.count >= 23 ? stampFormat.date(from: String(line.prefix(23))) : nil
    }

    private static func processStart() -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: Writing it out

    /// Every way an account can be named: its name, its address, its organization as its folder spells it.
    static func names(of account: AccountStatus) -> [String] {
        let c = account.config
        // A generic row's name is its app's ("Dropbox"), nobody's: only its folder's account part is personal (C3).
        var names = account.provider.isBeta ? [] : [account.name, c.fallbackName]
        if account.provider.isBeta { names += GenericProvider.parts(of: c.folder.lastPathComponent).account.map { [$0] } ?? [] }
        if c.key.hasPrefix("googledrive:") { names.append(String(c.key.dropFirst("googledrive:".count))) }
        for url in [c.folder] + c.watchRoots + c.places.map({ URL(fileURLWithPath: $0.path) }) {
            let folder = url.lastPathComponent
            if folder.hasPrefix("OneDrive-") {
                names.append(String(folder.dropFirst("OneDrive-".count)))
                names.append(OneDriveFiles.fallbackName(kind: .business, folder: url))
            } else if folder.hasPrefix(GoogleDriveProvider.folderPrefix) {
                names.append(String(folder.dropFirst(GoogleDriveProvider.folderPrefix.count)))
            }
        }
        return names
    }

    /// The redactor for one report, loaded with everything the input knows is personal.
    static func redactor(for input: DiagnosticsInput) -> (Redactor, [String: String]) {
        let r = Redactor(home: input.home)
        var labels: [String: String] = [:]
        for account in input.snapshot.accounts {
            labels[account.id] = r.account(names(of: account))
        }
        r.person(input.userNames)
        if let computer = input.computerName { r.computer(computer) }
        for id in input.driveFSIDs { r.id(id) }
        for account in input.snapshot.accounts {
            for url in [account.config.folder] + account.config.watchRoots { r.root(url.path) }
            for place in account.config.places { r.root(place.path) }
        }
        for file in input.snapshot.stuck.files { r.file(file.name) }
        for item in input.snapshot.activity { r.file(item.name) }
        for account in input.snapshot.accounts {
            if let failure = account.firstFailure, let name = failure.components(separatedBy: ": ").first { r.file(name) }
        }
        r.harvest(input.log.lines)
        return (r, labels)
    }

    @MainActor
    static func render(_ input: DiagnosticsInput) -> String {
        let (r, labels) = redactor(for: input)
        let snapshot = input.snapshot
        let now = input.now
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }
        func onOff(_ on: Bool) -> String { on ? "on" : "off" }
        func ago(_ date: Date) -> String { RelTime.string(date, now: now) }
        func label(_ key: String) -> String { labels[key] ?? r.text(key) }

        line("Velum diagnostics (redacted)")
        line("Made \(now.formatted(date: .abbreviated, time: .shortened)) on this Mac. Velum doesn’t send it anywhere.")
        line("Velum replaced what it knows is personal: account names and emails (Account 1, <email 1>), organization names (<org 1>), the home folder (~), folders inside synced folders (…), file names (file-1.docx, the extension kept), storage figures (<size>, <percent>), Google account IDs (<id 1>) and web addresses (<url>). It can’t recognize everything, so read it before you share it.")
        switch input.origin {
        case .app: line("Read from: the running Velum, as its panel shows it.")
        case .terminal: line("Read from: Terminal (Velum --dump --redact), a fresh look apart from the running Velum. The optional Google sign-in isn’t asked from here.")
        }

        line()
        line("Velum and this Mac")
        var velum = [input.velumVersion]
        if let built = input.velumBuilt { velum.append("built \(built.formatted(date: .abbreviated, time: .shortened))") }
        if let since = input.runningSince { velum.append("running for \(Reasons.duration(now.timeIntervalSince(since)))") }
        line("  " + velum.joined(separator: " · "))
        line("  " + [input.macOS, input.model, input.chip, input.language.isEmpty ? "" : "language \(input.language)"]
            .filter { !$0.isEmpty }.map(r.text).joined(separator: " · "))
        let clients = snapshot.providers.map { p -> String in
            p.id == .iCloud ? "iCloud Drive comes with macOS" : "\(p.id.name) \(p.compatibility?.version ?? "version unknown")"
        }
        line("  " + (clients.isEmpty ? "No sync service found" : clients.joined(separator: " · ")))

        line()
        line("Settings")
        line("  Notify About Problems: \(onOff(input.notifications))")
        line("  Open at Login: \(onOff(input.openAtLogin))")
        line("  Debug Logging: \(onOff(input.debugLogging))")
        if snapshot.oneDrive != nil {
            line("  OneDrive’s exact status (Accessibility): \(snapshot.axTrusted ? "allowed" : "not allowed")")
        }
        line("  A file counts as stuck after: \(Reasons.duration(input.stuckAfter))\(input.stuckAfterOverridden ? " (set with stuckAfterSeconds)" : "")")
        let google = snapshot.accounts.filter { $0.provider == .googleDrive }
        if !google.isEmpty {
            let switches = google.map { "\(label($0.id)) \(onOff(input.googleSignInOn.contains($0.config.fallbackName.lowercased())))" }
            line("  Google sign-in: " + (input.googleSignInAvailable ? switches.joined(separator: ", ") : "not in this build"))
        }

        line()
        let lid = LidRow(verdict: snapshot.lidVerdict)
        line("Close the lid?")
        line("  " + r.text("\(lid.title). \(lid.subtitle) (\(snapshot.lidVerdict))"))

        line()
        line("Services")
        for provider in snapshot.providers {
            var parts: [String] = []
            switch provider.id {
            case .oneDrive:
                parts = ["app \(provider.clientRunning == true ? "running" : "not running")",
                         "icon text readable: \(snapshot.liveItemsFound ? "yes" : "no")"]
            case .iCloud:
                let iCloud = snapshot.accounts.first { $0.provider == .iCloud }
                parts = ["no app of its own (part of macOS)",
                         "Desktop & Documents in iCloud: \((iCloud?.config.watchRoots.count ?? 0) > 1 ? "yes" : "no")"]
            case .googleDrive:
                parts = ["app \(provider.clientRunning == true ? "running" : "not running")"]
                if let paused = input.googlePaused { parts.append("paused: \(paused ? "yes (user-paused file)" : "no")") }
            case .cloudStorage:
                parts = ["beta", "macOS’s file flags only", "no app Velum can start or stop"]
            }
            if let trouble = provider.trouble { parts.append(r.text(trouble)) }
            line("  \(provider.id.name): " + parts.joined(separator: " · "))
        }

        line()
        line("Compatibility (what Velum reads, checked against the versions it was tested with)")
        let reports = snapshot.providers.compactMap(\.compatibility)
        if reports.isEmpty { line("  Nothing checked yet") }
        for text in reports.flatMap(\.dumpLines) { line(r.text(text)) }

        for account in snapshot.accounts {
            line()
            accountSection(account, label: label(account.id), input: input, r: r, line: line)
        }

        line()
        let stuck = snapshot.stuck
        let listed = stuck.files.count < stuck.total ? ", the first \(stuck.files.count) listed" : ""
        line("Not in the cloud yet: \(stuck.total == 1 ? "1 file" : "\(stuck.total) files") (failing, or waiting at least \(Reasons.duration(input.stuckAfter)))\(listed)")
        for file in stuck.files {
            let state = switch file.status {
            case .waiting: "waiting"
            case .uploading: "uploading"
            case .failed(let reason): "failing: \(r.foreign(reason))"
            }
            line("  \(label(file.account)) · \(r.path(file.path)) · changed \(ago(file.since)) · \(state)")
        }

        line()
        let recent = snapshot.activity.prefix(10)
        line("Recent activity" + (snapshot.activity.count > recent.count ? " (the newest \(recent.count) of \(snapshot.activity.count))" : ""))
        if recent.isEmpty { line("  None") }
        for item in recent {
            let verb = item.verb.padding(toLength: 11, withPad: " ", startingAt: 0)
            let when = ago(item.date).padding(toLength: 12, withPad: " ", startingAt: 0)
            line("  \(verb)\(when)\(label(item.accountKey)) · \(r.file(item.name))")
        }

        line()
        let log = input.log
        let hours = Int(log.window / 3600)
        if log.lines.isEmpty {
            line("Debug log: nothing in the last \(hours) hours. Debug Logging is \(onOff(input.debugLogging)) (••• → Debug Logging).")
        } else {
            let span = [log.lines.first, log.lines.last].compactMap { $0.flatMap(stamp) }
                .map { $0.formatted(date: .abbreviated, time: .shortened) }
            let count = log.total > log.lines.count ? "the newest \(log.lines.count) of \(log.total) lines" : "\(log.lines.count) line\(log.lines.count == 1 ? "" : "s")"
            line("Debug log (~/Library/Logs/Velum/Velum.log), the last \(hours) hours: \(count)\(span.count == 2 ? ", \(span[0]) to \(span[1])" : "")")
            for text in log.lines { line("  " + r.foreign(text)) }
        }
        return out.joined(separator: "\n") + "\n"
    }

    private static func accountSection(_ account: AccountStatus, label: String, input: DiagnosticsInput, r: Redactor,
                                       line: (String) -> Void) {
        let now = input.now
        let c = account.config
        func ago(_ date: Date) -> String { RelTime.string(date, now: now) }
        line("\(label) · \(account.provider.name) · key \(r.text(c.key))")
        line("  status: \(account.state) · \(r.text(account.headline))")
        if !account.source.isEmpty || !account.age.isEmpty {
            line("  source: \(account.source.isEmpty ? "none" : r.text(account.source)) · age: \(account.age.isEmpty ? "none" : account.age)\(account.isOld ? " · old" : "")")
        }
        if let reason = account.reason { line("  why: \(r.text(reason))") }
        if !account.notes.isEmpty { line("  notes: \(r.text(account.notes))") }
        if !account.detail.isEmpty { line("  row: \(r.foreign(account.detail))") }
        line("  evidence: " + evidence(account, input: input, r: r))
        line("  storage: " + (account.storageSource.map(r.text) ?? (account.provider == .oneDrive ? "none (OneDrive gives Velum none)" : "none")))

        var uploads = [account.uploadsCovered ? "watching every change" : "can’t vouch for every change (a gap, or just started watching)"]
        var pending = "\(account.uploadsPending) waiting or uploading"
        if let oldest = account.oldestWaiting { pending += ", oldest since \(RelTime.clock(oldest)) (\(ago(oldest)))" }
        uploads.append(pending)
        uploads.append("\(account.uploadsFailed) failing" + (account.firstFailure.map { ", first: \(r.foreign($0))" } ?? ""))
        if account.workPending {
            uploads.append("the service’s own queue has work" + (account.workingSince.map { " since \(RelTime.clock($0))" } ?? ""))
        }
        line("  uploads: " + uploads.joined(separator: " · "))
        if let t = input.transfers[account.id], t.isActive {
            var parts = ["up \(t.uploadingFiles)", "down \(t.downloadingFiles)", "direction unknown \(t.otherFiles)"]
            if t.bytesTotal > 0 { parts.append("\(Int((Double(t.bytesDone) / Double(t.bytesTotal) * 100).rounded()))% of the bytes") }
            line("  transfers: " + parts.joined(separator: " · "))
        } else {
            line("  transfers: none")
        }
        if account.provider == .oneDrive {
            line("  process: \(account.pid.map(String.init) ?? "none matched") · icon text: \(account.isLive ? "yes" : "no")")
        }
        line("  folder: \(r.path(c.folder.path))")
        let watched = c.watchRoots.map { r.path($0.path) }
        if watched != [r.path(c.folder.path)] { line("  watching: " + watched.joined(separator: ", ")) }
    }

    /// The account's own evidence, as read: OneDrive's hourly report, iCloud's `brctl status`, Google Drive's
    /// queue and pause.
    private static func evidence(_ account: AccountStatus, input: DiagnosticsInput, r: Redactor) -> String {
        let checks = input.snapshot.providers.first { $0.id == account.provider }?.compatibility?.checks ?? []
        func check(_ name: String, account key: String?) -> InternalCheck? {
            checks.first { $0.name == name && $0.accountKey == key }
        }
        switch account.provider {
        case .oneDrive:
            switch input.oneDriveReports[account.id] {
            case .read(let d)?:
                let code = d.progressState.map(String.init) ?? "no status line"
                return "OneDrive report (SyncDiagnostics.log), written \(RelTime.clock(d.written)), \(RelTime.string(d.written, now: input.now)): "
                    + "SyncProgressState \(code) · FilesToUpload \(d.filesToUpload) · FilesToDownload \(d.filesToDownload) · "
                    + "files \(d.files) · folders \(d.folders) · pid \(d.pid.map(String.init) ?? "none")"
            case .unreadable?: return "OneDrive report (SyncDiagnostics.log) is there, but Velum couldn’t read it"
            case .missing?: return "no OneDrive report on disk yet"
            case nil: return "none (found from its folder alone)"
            }
        case .iCloud:
            guard let status = check("status report (brctl status)", account: nil) else { return "brctl status hasn’t answered yet" }
            return "brctl status: " + r.text(status.detail.isEmpty ? status.result.rawValue : status.detail)
        case .googleDrive:
            let queue = check("queue (operations table)", account: account.id)
            var parts = ["Google Drive’s queue: " + (queue.map { r.text($0.detail.isEmpty ? $0.result.rawValue : $0.detail) } ?? "not read")]
            if let paused = input.googlePaused { parts.append("paused: \(paused ? "yes" : "no")") }
            return parts.joined(separator: " · ")
        case .cloudStorage:
            return "macOS’s file flags only · " + r.text(GenericText.dumpLine(GenericProvider.identify(account.config.folder)))
        }
    }
}
