import Foundation

/// What the status file says at one moment, as `velumctl` reads it. Missing, unreadable, newer, stale or from a
/// Velum that has quit all mean "unknown", never the last good answer.
public struct StatusReading: Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        /// No file: Velum isn't running, or hasn't finished its first refresh.
        case missing
        case unreadable
        /// Written by a newer Velum in a schema this reader doesn't know.
        case newerSchema(Int)
        /// The Velum that wrote it has quit.
        case appNotRunning
        /// Older than two refresh intervals (its age in seconds).
        case stale(TimeInterval)
        /// Dated later than this Mac's clock.
        case future
        /// Says "safe" while its own accounts or services say otherwise: never trusted (a bug, or a hand-edited file).
        case inconsistent
    }

    /// Only while fresh.
    public var document: StatusDocument?
    public var written: Date?
    public var age: TimeInterval?
    public var problem: Problem?
    /// The answer: the file's own while fresh, unknown with the problem as its reason otherwise.
    public var lid: Lid

    public var fresh: Bool { document != nil }

    /// A refresh may run late now and then; below this a status never counts as stale.
    public static let minimumStaleAfter: TimeInterval = 5
    /// A status dated later than the clock by more than this decides nothing (the clock was set back).
    public static let futureTolerance: TimeInterval = 1
    /// The longest refresh interval a file may claim, so a bad value can't keep a status fresh for long; a value
    /// that isn't a positive number counts as the app's own 2.5 s.
    public static let maximumRefreshEvery: TimeInterval = 30
    public static let defaultRefreshEvery: TimeInterval = 2.5

    public static func read(_ url: URL = StatusDocument.defaultURL, now: Date = Date(),
                            isRunning: (Int32) -> Bool = processExists) -> StatusReading {
        guard FileManager.default.fileExists(atPath: url.path) else { return unknown(.missing) }
        return interpret(FileManager.default.contents(atPath: url.path), now: now, isRunning: isRunning)
    }

    /// `data` nil: the file exists but can't be read.
    public static func interpret(_ data: Data?, now: Date, isRunning: (Int32) -> Bool) -> StatusReading {
        guard let data else { return unknown(.unreadable) }
        struct Header: Decodable { var schema: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return unknown(.unreadable) }
        guard header.schema <= StatusDocument.schemaVersion else { return unknown(.newerSchema(header.schema)) }
        guard header.schema == StatusDocument.schemaVersion,
              var document = try? StatusDocument.decoder().decode(StatusDocument.self, from: data) else {
            return unknown(.unreadable)
        }
        document.lid.exitCode = document.lid.verdict.exitCode
        let age = now.timeIntervalSince(document.written)
        let every = document.refreshEvery.isFinite && document.refreshEvery > 0
            ? min(document.refreshEvery, maximumRefreshEvery) : defaultRefreshEvery
        var reading = StatusReading(written: document.written, age: age, lid: document.lid)
        if age < -futureTolerance {
            reading.problem = .future
        } else if !isRunning(document.app.pid) {
            reading.problem = .appNotRunning
        } else if age > max(2 * every, minimumStaleAfter) {
            reading.problem = .stale(age)
        } else if document.lid.verdict == .safe, !document.supportsSafe {
            reading.problem = .inconsistent
        } else {
            reading.document = document
            return reading
        }
        reading.lid = .unknown(reading.problem!.reason)
        return reading
    }

    private static func unknown(_ problem: Problem) -> StatusReading {
        StatusReading(problem: problem, lid: .unknown(problem.reason))
    }

    /// Whether a process with this ID exists (any process: a reused ID lasts at most until the status goes stale).
    public static func processExists(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

extension StatusReading.Problem {
    var reason: String {
        switch self {
        case .missing: "There’s no status from Velum yet. It isn’t running, or has only just started."
        case .unreadable: "Velum’s status file can’t be read."
        case .newerSchema: "This velumctl is older than the running Velum. Use the one inside Velum.app."
        case .appNotRunning: "Velum isn’t running."
        case .stale(let age): "Velum’s last status is \(Words.duration(age)) old. Things may have changed since."
        case .future: "Velum’s status is dated later than this Mac’s clock."
        case .inconsistent: "Velum’s status file contradicts itself, so it can’t be trusted."
        }
    }
}

extension StatusDocument {
    /// Whether the rest of the file allows "safe": the same conditions the app's lid line checks, so a file can
    /// only say "safe" when its own services and accounts agree.
    var supportsSafe: Bool {
        !services.isEmpty && !accounts.isEmpty
            && services.allSatisfy { $0.appRunning != false }
            && accounts.allSatisfy { a in
                a.state != .notRunning && a.uploads.pending == 0 && a.uploads.failed == 0 && a.uploads.covered
                    && !a.uploads.serviceBusy
            }
    }
}

/// `velumctl`'s output, `--json`. Schema 1, like the file. Parts a command doesn't show, and every part but the
/// lid while the status isn't fresh, are left out.
public struct Answer: Codable, Equatable, Sendable {
    public var schema = StatusDocument.schemaVersion
    /// The status is current: from a running Velum, within two refresh intervals.
    public var fresh: Bool
    public var written: Date?
    /// Seconds since Velum wrote it.
    public var ageSeconds: Double?
    public var lid: Lid
    public var refreshEvery: Double?
    public var app: AppInfo?
    public var state: AccountState?
    public var summary: String?
    public var services: [Service]?
    public var accounts: [Account]?
    public var pending: Pending?
}

public enum VelumCtl {
    public enum Command: String, CaseIterable, Sendable { case status, lid, pending }

    public struct Output: Equatable, Sendable {
        public var stdout = ""
        public var stderr = ""
        public var code: Int32 = 0
    }

    public static let usageCode: Int32 = 64

    public static let usage = """
    usage: velumctl [status|lid|pending] [--json]
           velumctl --version

      status    every service and account, as Velum’s panel shows them (the default)
      lid       is it safe to close the lid?
      pending   files not in the cloud yet, by name

      --json    machine-readable output (see docs/velumctl.md)

    Exit status, for every command:
      0  safe to close the lid
      1  files are still on the way up, or a service is still syncing
      2  files can’t upload, or a sync app isn’t running
      3  can’t tell (Velum can’t vouch, isn’t running, or its status is out of date)
     64  usage error

    """

    /// Runs one command line. `reading` is asked only when a command needs the status.
    public static func run(_ arguments: [String], version: String, reading: () -> StatusReading) -> Output {
        var json = false
        var command: Command?
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "-h", "--help", "help": return Output(stdout: usage)
            case "--version", "version": return Output(stdout: "velumctl \(version) · status schema \(StatusDocument.schemaVersion)\n")
            default:
                guard command == nil, let known = Command(rawValue: argument) else {
                    return Output(stderr: "velumctl: unknown argument ‘\(argument)’\n\n" + usage, code: usageCode)
                }
                command = known
            }
        }
        let reading = reading()
        let text = json ? Self.json(command ?? .status, reading) : Self.text(command ?? .status, reading)
        // From the verdict itself, never the stored number: a file whose fields disagree can't exit 0.
        return Output(stdout: text, code: reading.lid.verdict.exitCode)
    }

    // MARK: JSON

    public static func answer(_ command: Command, _ reading: StatusReading) -> Answer {
        var answer = Answer(fresh: reading.fresh, written: reading.written,
                            ageSeconds: reading.age.map { ($0 * 10).rounded() / 10 }, lid: reading.lid)
        guard let document = reading.document else { return answer }
        if command == .status {
            answer.refreshEvery = document.refreshEvery
            answer.app = document.app
            answer.state = document.state
            answer.summary = document.summary
            answer.services = document.services
            answer.accounts = document.accounts
        }
        if command != .lid { answer.pending = document.pending }
        return answer
    }

    static func json(_ command: Command, _ reading: StatusReading) -> String {
        let data = (try? StatusDocument.encoder().encode(answer(command, reading))) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: Text

    /// No "as of" footer: a status old enough for its age to matter is already "unknown".
    static func text(_ command: Command, _ reading: StatusReading) -> String {
        var lines = ["\(reading.lid.title). \(reading.lid.detail)"]
        if let document = reading.document {
            switch command {
            case .lid: break
            case .status: lines = status(document, lid: lines[0])
            case .pending: lines += pending(document)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Like the panel: the summary and the lid line, then a heading per service with its accounts under it.
    static func status(_ document: StatusDocument, lid: String) -> [String] {
        var lines = [document.summary, lid]
        for service in document.services {
            let accounts = document.accounts.filter { $0.service == service.id }
            guard !accounts.isEmpty || service.appRunning == false else { continue }
            lines.append("")
            var heading = service.name
            if service.appRunning == false {
                heading += " · Not running"
            } else if let trouble = service.trouble {
                heading += " · \(trouble)"
            }
            lines.append(heading)
            for account in accounts {
                lines.append("  \(account.name): \(account.headline)")
                for line in [account.reason, account.notes, account.detail].compactMap({ $0 }) where !line.isEmpty {
                    lines.append("    \(line)")
                }
            }
        }
        if document.services.isEmpty { lines += ["", "No cloud accounts found."] }
        return lines
    }

    /// Files not in the cloud yet, failing first, then oldest.
    static func pending(_ document: StatusDocument) -> [String] {
        let pending = document.pending
        guard pending.total > 0 else {
            // The lid also counts uploads macOS reports in progress before Velum has checked the file (seen live).
            if document.lid.verdict == .pending, let n = document.lid.files, n > 0 {
                return ["", n == 1 ? "Velum can’t name it yet: macOS reported the upload before Velum checked the file."
                                   : "Velum can’t name them yet: macOS reported the uploads before Velum checked the files."]
            }
            return ["", "No files Velum tracks are waiting to upload."]
        }
        let names = Dictionary(document.accounts.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        var lines = ["", pending.total == 1 ? "1 file isn’t in the cloud yet:" : "\(pending.total) files aren’t in the cloud yet:"]
        for file in pending.files {
            let state = switch file.status {
            case .waiting: file.stuck ? "waiting · stuck" : "waiting"
            case .uploading: file.stuck ? "uploading · stuck" : "uploading"
            case .failing: "can’t upload" + (file.reason.map { ": " + $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? "")
            }
            lines.append("  \((file.path as NSString).abbreviatingWithTildeInPath)")
            lines.append("    \(names[file.account] ?? file.account) · \(state) · changed \(Words.ago(document.written.timeIntervalSince(file.since)))")
        }
        let unlisted = pending.total - pending.files.count
        if unlisted > 0 { lines.append("  …and \(unlisted) more.") }
        return lines
    }
}

/// Times in words, in the panel's style.
enum Words {
    /// "just now", "4 min ago", "2 hr ago", "3 days ago".
    static func ago(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        if s < 86_400 { return "\(Int(s / 3600)) hr ago" }
        let days = Int(s / 86_400)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    /// "8 seconds", "1 minute", "3 hours", "2 days".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        func unit(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }
        if s < 60 { return unit(s, "second") }
        if s < 3600 { return unit(s / 60, "minute") }
        if s < 86_400 { return unit(s / 3600, "hour") }
        return unit(s / 86_400, "day")
    }
}
