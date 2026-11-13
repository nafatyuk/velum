import Foundation

// Card T1: the status file. After every refresh the running Velum writes what its panel shows to
// `~/Library/Application Support/Velum/status.json` (mode 0600, replaced atomically); `velumctl` reads it, and
// later T2's Shortcuts and T3's widget can too. Like a departures board: the station updates it, anyone walking
// past can read it, and it says when it was last updated.
//
// Schema rules (docs/velumctl.md has the field list):
// - `schema` goes up only when a key is renamed or removed, a value changes meaning, or an enum gains a value.
//   New keys may appear within a schema; readers ignore keys they don't know.
// - A reader refuses a schema newer than it knows and answers "unknown". It never guesses.
// - Services, accounts and files are lists of any length with any keys ("googledrive:<email>"): never assume
//   three services or fixed account keys.
// - A key with no value (nothing known, or not applying) is left out rather than written as null.

/// Everything the running Velum knew at `written`. Schema 1.
public struct StatusDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public var schema: Int
    /// When the app wrote it: the end of a refresh.
    public var written: Date
    /// Seconds between refreshes. A status older than two of these is stale: "unknown", never the last answer.
    public var refreshEvery: Double
    public var app: AppInfo
    /// The menu bar icon's state: the worst account, or a stopped app.
    public var state: AccountState
    /// The panel's summary line ("Everything is up to date").
    public var summary: String
    public var lid: Lid
    public var services: [Service]
    public var accounts: [Account]
    public var pending: Pending

    public init(written: Date, refreshEvery: Double, app: AppInfo, state: AccountState, summary: String, lid: Lid,
                services: [Service], accounts: [Account], pending: Pending) {
        schema = Self.schemaVersion
        self.written = written
        self.refreshEvery = refreshEvery
        self.app = app
        self.state = state
        self.summary = summary
        self.lid = lid
        self.services = services
        self.accounts = accounts
        self.pending = pending
    }

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Velum/status.json")
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var version: String?
    public var build: String?
    public var pid: Int32

    public init(version: String?, build: String?, pid: Int32) {
        self.version = version
        self.build = build
        self.pid = pid
    }
}

/// An account's state, as the panel's row shows it. Ordered from fine to worst, like the app's.
public enum AccountState: String, Codable, Sendable {
    case ok, unknown, syncing, offline, paused, warning, notRunning, error
}

/// "Is it safe to close the lid?", with the panel's words.
public struct Lid: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// Every change Velum watches is in the cloud.
        case safe
        /// Files on their way up (`files`).
        case pending
        /// Nothing counted is waiting, but a service's own queue still has work (`account`).
        case busy
        /// Files that can't upload (`files`).
        case failing
        /// A sync app isn't running (`service`), so new changes stay on this Mac.
        case notRunning
        /// Velum can't vouch (`reason`).
        case unknown

        /// `velumctl`'s exit code for this answer: 0 safe, 1 wait, 2 something needs you, 3 can't tell.
        public var exitCode: Int32 {
            switch self {
            case .safe: 0
            case .pending, .busy: 1
            case .failing, .notRunning: 2
            case .unknown: 3
            }
        }
    }

    public var verdict: Verdict
    public var files: Int?
    public var service: String?
    public var account: String?
    public var reason: String?
    /// The lid line's headline and detail, as the panel words them.
    public var title: String
    public var detail: String
    public var exitCode: Int32

    private init(_ verdict: Verdict, files: Int? = nil, service: String? = nil, account: String? = nil,
                 reason: String? = nil, detail: String) {
        self.verdict = verdict
        self.files = files
        self.service = service
        self.account = account
        self.reason = reason
        title = switch verdict {
        case .safe: "Safe to close the lid"
        case .pending, .busy: "Wait before closing the lid"
        case .failing, .notRunning: "Not everything is in the cloud"
        case .unknown: "Can’t vouch for every change"
        }
        self.detail = detail
        exitCode = verdict.exitCode
    }

    public static let safe = Lid(.safe, detail: "Every change in the watched cloud folders is in the cloud.")
    public static func pending(_ n: Int) -> Lid { Lid(.pending, files: n, detail: "\(files(n)) still on the way up.") }
    public static func busy(_ account: String) -> Lid { Lid(.busy, account: account, detail: "\(account) is still syncing changes.") }
    public static func failing(_ n: Int) -> Lid { Lid(.failing, files: n, detail: "\(files(n)) can’t upload.") }
    public static func notRunning(_ service: String) -> Lid {
        Lid(.notRunning, service: service, detail: "\(service) isn’t running, so new changes stay on this Mac.")
    }
    public static func unknown(_ reason: String) -> Lid {
        Lid(.unknown, reason: reason, detail: ".?!".contains(reason.last ?? " ") ? reason : reason + ".")
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
}

/// A sync service present on this Mac, under its heading in the panel.
public struct Service: Codable, Equatable, Sendable {
    /// "onedrive", "icloud", "googledrive"; others may appear.
    public var id: String
    public var name: String
    /// Whether its app runs. Left out when there is no app to run (iCloud is part of macOS).
    public var appRunning: Bool?
    /// A service-wide problem beside the heading ("Storage full").
    public var trouble: String?
    /// The service's own pause switch, where it has one Velum reads (Google Drive's). Left out elsewhere:
    /// OneDrive pauses per account, and that shows as the account's state.
    public var paused: Bool?
    /// Card A7: how the app's internals read against the versions Velum was tested with.
    public var compatibility: Compatibility?

    public init(id: String, name: String, appRunning: Bool?, trouble: String?, paused: Bool?, compatibility: Compatibility?) {
        self.id = id
        self.name = name
        self.appRunning = appRunning
        self.trouble = trouble
        self.paused = paused
        self.compatibility = compatibility
    }
}

public struct Compatibility: Codable, Equatable, Sendable {
    /// "OneDrive 26.212 (26.212.1029) · tested · every check passes".
    public var headline: String
    public var version: String?
    public var tested: Bool
    /// Internals that don't read as tested right now; while any does, the statuses that leaned on it are unknown.
    public var checksNotPassing: Int

    public init(headline: String, version: String?, tested: Bool, checksNotPassing: Int) {
        self.headline = headline
        self.version = version
        self.tested = tested
        self.checksNotPassing = checksNotPassing
    }
}

/// One account's row.
public struct Account: Codable, Equatable, Sendable {
    /// Velum's key for the account: "Personal", "Business1", "iCloudDrive", "googledrive:<email>". Stable while
    /// the account exists; accounts come and go at run time.
    public var key: String
    /// The service's `id`.
    public var service: String
    public var name: String
    public var state: AccountState
    public var headline: String
    /// The row's last line: the source with its age, the last change.
    public var detail: String?
    /// Where the headline came from ("From OneDrive", "Live from macOS", "OneDrive report, 1:45 PM").
    public var source: String?
    /// How old the status's evidence is ("live", "12 min ago").
    public var age: String?
    /// The status rests on an old report: never green, and the row says so.
    public var old: Bool
    /// Why Velum can't tell (or can't vouch), and what would end it (card A4).
    public var reason: String?
    /// Facts about the account ("Desktop & Documents included · 214 GB free").
    public var notes: String?
    /// The notes need the eye (storage almost full or full).
    public var notesNeedAttention: Bool
    /// The headline is the app's own words (OneDrive's icon text), not Velum's.
    public var headlineFromApp: Bool
    public var lastChange: Date?
    public var uploads: Uploads
    public var storage: Storage?

    public init(key: String, service: String, name: String, state: AccountState, headline: String, detail: String?,
                source: String?, age: String?, old: Bool, reason: String?, notes: String?, notesNeedAttention: Bool,
                headlineFromApp: Bool, lastChange: Date?, uploads: Uploads, storage: Storage?) {
        self.key = key
        self.service = service
        self.name = name
        self.state = state
        self.headline = headline
        self.detail = detail
        self.source = source
        self.age = age
        self.old = old
        self.reason = reason
        self.notes = notes
        self.notesNeedAttention = notesNeedAttention
        self.headlineFromApp = headlineFromApp
        self.lastChange = lastChange
        self.uploads = uploads
        self.storage = storage
    }
}

/// Local changes not in the cloud yet, from Velum's own tracking.
public struct Uploads: Codable, Equatable, Sendable {
    /// Waiting or uploading.
    public var pending: Int
    public var failed: Int
    /// Failing, or waiting at least `Pending.stuckAfter` (card A3).
    public var stuck: Int
    public var oldestWaiting: Date?
    /// The first failing file: "<file name>: <reason>".
    public var firstFailure: String?
    /// Velum watches every folder of the account with no known gap, so these counts are complete.
    public var covered: Bool
    /// The service's own queue holds work that isn't a counted file (Google Drive), and since when.
    public var serviceBusy: Bool
    public var serviceBusySince: Date?

    public init(pending: Int, failed: Int, stuck: Int, oldestWaiting: Date?, firstFailure: String?, covered: Bool,
                serviceBusy: Bool, serviceBusySince: Date?) {
        self.pending = pending
        self.failed = failed
        self.stuck = stuck
        self.oldestWaiting = oldestWaiting
        self.firstFailure = firstFailure
        self.covered = covered
        self.serviceBusy = serviceBusy
        self.serviceBusySince = serviceBusySince
    }
}

/// The account's cloud storage, in bytes, where Velum knows it.
public struct Storage: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Google Drive's own cache on this Mac.
        case googleDriveCache
        /// The optional Google sign-in (asked only when Drive's cache has none).
        case googleSignIn
        /// macOS's `brctl quota`, for iCloud.
        case iCloudQuota
    }

    /// Left out on an unlimited plan, or when only the free space is known (iCloud).
    public var limit: Int64?
    public var used: Int64?
    public var free: Int64?
    /// What the account's own files use, when the service says (Google: the rest is Gmail and Photos).
    public var usedByFiles: Int64?
    public var full: Bool
    public var source: Source
    /// When the figures were read.
    public var asOf: Date?

    public init(limit: Int64?, used: Int64?, free: Int64?, usedByFiles: Int64?, full: Bool, source: Source, asOf: Date?) {
        self.limit = limit
        self.used = used
        self.free = free
        self.usedByFiles = usedByFiles
        self.full = full
        self.source = source
        self.asOf = asOf
    }
}

/// Files not in the cloud yet (card A3's listing): failing first, then oldest first.
public struct Pending: Codable, Equatable, Sendable {
    /// Every file not in the cloud yet that Velum tracks, listed or not.
    public var total: Int
    /// Of those, failing or waiting at least `stuckAfter`: the panel's "Not in the cloud yet" list.
    public var stuck: Int
    /// Seconds a change may wait before its file counts as stuck.
    public var stuckAfter: Double
    /// At most 50, with names and paths: the file stays on this Mac.
    public var files: [PendingFile]

    public init(total: Int, stuck: Int, stuckAfter: Double, files: [PendingFile]) {
        self.total = total
        self.stuck = stuck
        self.stuckAfter = stuckAfter
        self.files = files
    }
}

public struct PendingFile: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case waiting, uploading, failing }

    /// The account's `key`.
    public var account: String
    public var path: String
    public var name: String
    /// When its latest change happened.
    public var since: Date
    public var status: Status
    /// Failing: the service's reason, as macOS words it.
    public var reason: String?
    public var stuck: Bool

    public init(account: String, path: String, since: Date, status: Status, reason: String?, stuck: Bool) {
        self.account = account
        self.path = path
        name = (path as NSString).lastPathComponent
        self.since = since
        self.status = status
        self.reason = reason
        self.stuck = stuck
    }
}

// MARK: - Encoding and the file

public extension StatusDocument {
    /// Sorted, indented JSON with ISO 8601 dates (milliseconds, UTC) and unescaped slashes.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(StatusDates.string(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = StatusDates.date(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
            }
            return date
        }
        return decoder
    }

    /// Replaces the file at `url` in one step: a reader sees the old file or the new one, never half of either.
    /// The file is readable by this user only (0600) from the moment it exists, since it names files.
    func write(to url: URL) throws {
        let data = try Self.encoder().encode(self) + Data("\n".utf8)
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = folder.appending(path: ".\(url.lastPathComponent).\(getpid()).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var failure: Int32 = 0
        if fchmod(fd, 0o600) != 0 { failure = errno }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while failure == 0, offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno != EINTR { failure = errno } } else { offset += n }
            }
        }
        if close(fd) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temporary.path, url.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary.path)
            throw POSIXError(.init(rawValue: failure) ?? .EIO)
        }
    }
}

/// The file's dates: "2026-11-13T06:12:01.234Z".
enum StatusDates {
    // ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let precise: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func string(_ date: Date) -> String { precise.string(from: date) }

    /// Reads dates with or without fractional seconds, with any time zone offset.
    static func date(_ text: String) -> Date? { precise.date(from: text) ?? plain.date(from: text) }
}
