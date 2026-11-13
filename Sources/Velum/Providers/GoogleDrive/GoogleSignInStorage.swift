import AppKit
import Combine
import Foundation
import Security
import SwiftUI

/// The optional Google sign-in, per account: Google storage from the Drive API, for accounts whose Google
/// Drive cache has no figures. Off by default. While an account's switch is off, nothing here touches the
/// network or the Keychain; the switch itself lives in UserDefaults.
///
/// Demand-driven: the Google Drive provider asks `storage(for:)` only when Drive's own cache has no figures,
/// and only that question starts a fetch, so a cache with figures means no request at all. Fetches run about
/// every 30 minutes, and at most every 5 minutes after the panel opens.
final class GoogleSignInStorage: @unchecked Sendable {
    static let shared = GoogleSignInStorage()

    enum Phase: Equatable { case unavailable, off, signingIn, on, expired }

    enum Problem: Equatable {
        /// Google says the sign-in belongs to another address.
        case otherAccount(String)
        /// `invalid_grant`: expired or revoked.
        case signInExpired
        /// Google answered without storage figures.
        case noStorage
    }

    static let defaultsKey = "googleSignInAccounts"
    static let interval: TimeInterval = 30 * 60
    static let panelInterval: TimeInterval = 5 * 60

    private struct Account {
        var storage: GoogleStorage?
        var problem: Problem?
        var lastAttempt = Date.distantPast
        var fetching = false
        var access: (token: String, expires: Date)?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let tokens: TokenStore
    private let auth: GoogleAuth?
    private let now: () -> Date
    private var accounts: [String: Account] = [:]          // by lowercased email
    private var signingIn: [String: LoopbackReceiver] = [:]
    private var panelOpenedAt = Date.distantPast
    /// When the provider last asked for a note, which it does only while Drive's cache has no figures.
    private var cacheEmptyAt: [String: Date] = [:]
    /// Called (on any thread) when figures, notes or the menu's state change.
    var onChange: (() -> Void)?

    init(client: GoogleOAuthClient? = .load(), transport: HTTPTransport = URLSessionTransport(),
         defaults: UserDefaults = .standard, tokens: TokenStore = KeychainTokenStore(), now: @escaping () -> Date = Date.init) {
        self.auth = client.map { GoogleAuth(client: $0, transport: transport) }
        self.defaults = defaults
        self.tokens = tokens
        self.now = now
    }

    /// This build has an OAuth client to sign in with.
    var isAvailable: Bool { auth != nil }

    static func key(_ email: String) -> String { email.lowercased() }

    func isOn(_ email: String) -> Bool {
        (defaults.stringArray(forKey: Self.defaultsKey) ?? []).contains(Self.key(email))
    }

    private func setOn(_ email: String, _ on: Bool) {
        var list = Set(defaults.stringArray(forKey: Self.defaultsKey) ?? [])
        if on { list.insert(Self.key(email)) } else { list.remove(Self.key(email)) }
        if list.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else { defaults.set(list.sorted(), forKey: Self.defaultsKey) }
    }

    // MARK: The seam (collector's queue, never blocks)

    /// The latest figures for an account whose switch is on, starting a fetch in the background when they're
    /// due. nil when off, before the first answer, or when the sign-in has a problem (see `note(for:)`).
    func storage(for email: String) -> GoogleStorage? {
        guard auth != nil, isOn(email) else { return nil }
        let key = Self.key(email)
        let (figures, due): (GoogleStorage?, Bool) = lock.withLock {
            var account = accounts[key] ?? Account()
            let due = isDue(account)
            if due {
                account.fetching = true
                account.lastAttempt = now()
            }
            accounts[key] = account
            return (account.problem == nil ? account.storage : nil, due)
        }
        if due { Task { await self.fetch(email) } }
        return figures
    }

    /// What the row should say about the sign-in: while it waits for the browser, or when something's wrong
    /// with it. The provider asks only while Drive's cache has no figures, which also tells the menu whether
    /// "Show Storage…" would show anything.
    func note(for email: String) -> String? {
        guard auth != nil else { return nil }
        let key = Self.key(email)
        let (signing, problem): (Bool, Problem?) = lock.withLock {
            cacheEmptyAt[key] = now()
            return (signingIn[key] != nil, accounts[key]?.problem)
        }
        if signing { return "Waiting for Google sign-in…" }
        guard isOn(email) else { return nil }
        switch problem {
        case .otherAccount(let other)?: return "Storage not shown · the Google sign-in is for \(other)"
        case .signInExpired?: return "Storage not shown · sign in again from the ••• menu"
        case .noStorage?: return "Storage not shown · Google didn’t share it"
        case nil: return nil
        }
    }

    /// Drive's own cache had no storage figures on a recent refresh.
    func cacheLacksFigures(_ email: String) -> Bool {
        lock.withLock { cacheEmptyAt[Self.key(email)].map { now().timeIntervalSince($0) < 30 } ?? false }
    }

    func phase(for email: String) -> Phase {
        guard auth != nil else { return .unavailable }
        let key = Self.key(email)
        return lock.withLock {
            if signingIn[key] != nil { return .signingIn }
            if !isOn(email) { return .off }
            return accounts[key]?.problem == .signInExpired ? .expired : .on
        }
    }

    /// The panel opened: figures older than 5 minutes are fetched again on the next refresh.
    func panelOpened() {
        lock.withLock { panelOpenedAt = now() }
    }

    private func isDue(_ account: Account) -> Bool {
        guard !account.fetching, account.problem != .signInExpired else { return false }
        let age = now().timeIntervalSince(account.lastAttempt)
        return age >= Self.interval || (panelOpenedAt > account.lastAttempt && age >= Self.panelInterval)
    }

    // MARK: Fetching

    /// Asks Drive for the account's storage, refreshing the access token when needed. Keeps the last figures
    /// through a network failure; `invalid_grant` ends the sign-in until the user signs in again.
    func fetch(_ email: String) async {
        guard let auth else { return }
        let key = Self.key(email)
        defer {
            lock.withLock { accounts[key]?.fetching = false }
            onChange?()
        }
        do {
            var about: GoogleAbout
            do {
                about = try await auth.about(accessToken: try await accessToken(email, auth: auth), now: now())
            } catch GoogleSignInError.http(401) {
                lock.withLock { accounts[key]?.access = nil }      // stale token: refresh once and retry
                about = try await auth.about(accessToken: try await accessToken(email, auth: auth), now: now())
            }
            apply(about, to: email)
        } catch GoogleSignInError.signInExpired {
            tokens.delete(key)
            lock.withLock {
                accounts[key, default: Account()].problem = .signInExpired
                accounts[key]?.storage = nil
                accounts[key]?.access = nil
            }
        } catch {
            NSLog("Velum: Google storage for an account failed: \(error)")
        }
    }

    private func accessToken(_ email: String, auth: GoogleAuth) async throws -> String {
        let key = Self.key(email)
        if let access = lock.withLock({ accounts[key]?.access }), access.expires.timeIntervalSince(now()) > 60 {
            return access.token
        }
        guard let refresh = tokens.read(key) else { throw GoogleSignInError.signInExpired }
        let fresh = try await auth.refresh(refresh, now: now())
        lock.withLock { accounts[key, default: Account()].access = (fresh.access, fresh.expires) }
        return fresh.access
    }

    /// Figures only for the account the row is about: Google's own address for the sign-in must match.
    private func apply(_ about: GoogleAbout, to email: String) {
        let key = Self.key(email)
        lock.withLock {
            var account = accounts[key] ?? Account()
            if let signedIn = about.email, Self.key(signedIn) != key {
                account.problem = .otherAccount(signedIn)
                account.storage = nil
            } else if let storage = about.storage {
                account.problem = nil
                account.storage = storage
            } else {
                account.problem = .noStorage
                account.storage = nil
            }
            accounts[key] = account
        }
    }

    // MARK: Turning it on and off

    /// Signs in to Google for this account (the consent page opens in the default browser) and turns the
    /// switch on. Returns the first figures; throws when the user declines or the sign-in fails.
    @discardableResult
    func signIn(_ email: String, open: (URL) -> Void) async throws -> GoogleAbout {
        guard let auth else { throw GoogleSignInError.unexpected("this build has no Google OAuth client") }
        let key = Self.key(email)
        let receiver = try LoopbackReceiver()
        let started: Bool = lock.withLock {
            guard signingIn[key] == nil else { return false }
            signingIn[key] = receiver
            return true
        }
        guard started else { throw GoogleSignInError.cancelled }
        onChange?()
        defer {
            lock.withLock { signingIn[key] = nil }
            onChange?()
        }
        let (fresh, about) = try await auth.signIn(loginHint: email, receiver: receiver, open: open, now: now)
        guard let refresh = fresh.refresh else { throw GoogleSignInError.unexpected("no refresh token") }
        // A sign-in again replaces the old grant; revoke the old one so it doesn't linger at Google.
        if let old = tokens.read(key), old != refresh { await auth.revoke(old) }
        try tokens.write(refresh, for: key)
        setOn(email, true)
        lock.withLock {
            var account = Account()
            account.lastAttempt = now()
            account.access = (fresh.access, fresh.expires)
            accounts[key] = account
        }
        apply(about, to: email)
        return about
    }

    func cancelSignIn(_ email: String) {
        lock.withLock { signingIn[Self.key(email)] }?.cancel()
    }

    /// Turns the switch off: revokes the grant at Google, deletes the Keychain item and forgets the figures.
    func turnOff(_ email: String) async {
        let key = Self.key(email)
        cancelSignIn(email)
        let token = isOn(email) ? tokens.read(key) : nil
        tokens.delete(key)
        setOn(email, false)
        lock.withLock { accounts[key] = nil }
        onChange?()
        if let token, let auth { await auth.revoke(token) }
    }
}

// MARK: - The refresh token in the login Keychain

protocol TokenStore: AnyObject {
    func read(_ account: String) -> String?
    func write(_ token: String, for account: String) throws
    func delete(_ account: String)
}

/// A generic password per account email in the login Keychain.
final class KeychainTokenStore: TokenStore {
    static let service = "Velum Google Sign-In"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String, for account: String) throws {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrLabel as String] = Self.service
        q[kSecAttrDescription as String] = "Google refresh token (storage only)"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleSignInError.unexpected("Keychain error \(status)") }
    }

    func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

// MARK: - App wiring

extension GoogleSignInStorage {
    /// Connects the sign-in to the Google Drive provider and the panel. Called once at launch.
    @MainActor
    static func install() {
        let shared = Self.shared
        GoogleDriveProvider.signInStorage = { shared.storage(for: $0) }
        GoogleDriveProvider.signInNote = { shared.note(for: $0) }
        shared.onChange = {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    GoogleSignInMenu.shared.revision += 1
                    AppModel.store.refresh()
                }
            }
        }
        // The panel becoming key means it just opened.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            if note.object is MenuPanel { shared.panelOpened() }
        }
    }

    /// The ••• menu's action. Turning on closes the panel and says what will happen (Fable: an alert before
    /// the browser opens), since the consent page opens in the browser.
    @MainActor
    static func set(_ email: String, on: Bool) {
        let shared = Self.shared
        guard on else {
            Task { await shared.turnOff(email) }
            return
        }
        let phase = shared.phase(for: email)
        if phase == .signingIn {
            shared.cancelSignIn(email)
            return
        }
        AppModel.closePanel()
        guard confirm(email, again: phase == .expired) else { return }
        Task {
            do {
                try await shared.signIn(email) { NSWorkspace.shared.open($0) }
            } catch {
                NSLog("Velum: Google sign-in didn't finish: \(error)")
            }
        }
    }

    @MainActor
    private static func confirm(_ email: String, again: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = again ? "Sign in to Google again?" : "Show storage for \(email)?"
        alert.informativeText = "Velum will open Google in your browser. Google will ask to let Velum use only "
            + "the Drive files you use with it; Velum uses none, and reads only how much storage the account "
            + "has. The sign-in stays in your Keychain, and Stop Showing Storage removes it."
        alert.addButton(withTitle: "Continue in Browser")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The row's ••• items (Fable's wording): offered only when Drive's cache has no figures, since that's
    /// the only time the sign-in shows anything. With the cache showing storage, an existing sign-in can only
    /// be removed. Each item: its title, and whether it turns the sign-in on.
    static func menuItems(phase: Phase, cacheLacksFigures: Bool) -> [(title: String, on: Bool)] {
        switch phase {
        case .unavailable: return []
        case .off: return cacheLacksFigures ? [("Show Storage…", true)] : []
        case .signingIn: return [("Cancel Sign-In", true)]
        case .expired where cacheLacksFigures: return [("Sign In Again…", true), ("Stop Showing Storage", false)]
        case .on where cacheLacksFigures: return [("Stop Showing Storage", false)]
        case .on, .expired: return [("Remove Google Sign-In", false)]
        }
    }

    /// The email of a Google Drive account, from its key (`googledrive:<email>`).
    static func email(for config: AccountConfig) -> String? {
        guard config.provider == .googleDrive else { return nil }
        let prefix = "googledrive:"
        return config.key.hasPrefix(prefix) ? String(config.key.dropFirst(prefix.count)) : config.fallbackName
    }
}

/// Bumped whenever the sign-in changes, so open menus redraw.
@MainActor
final class GoogleSignInMenu: ObservableObject {
    static let shared = GoogleSignInMenu()
    @Published var revision = 0
}

/// The sign-in's items in a Google Drive row's ••• menu (see `GoogleSignInStorage.menuItems`); none in a
/// build without an OAuth client.
struct GoogleSignInMenuItems: View {
    let config: AccountConfig
    let set: @MainActor (_ email: String, _ on: Bool) -> Void
    @ObservedObject private var menu = GoogleSignInMenu.shared

    var body: some View {
        if let email = GoogleSignInStorage.email(for: config) {
            let shared = GoogleSignInStorage.shared
            let items = GoogleSignInStorage.menuItems(phase: shared.phase(for: email),
                                                      cacheLacksFigures: shared.cacheLacksFigures(email))
            ForEach(items, id: \.title) { item in
                Button(item.title) { set(email, item.on) }
            }
        }
    }
}

// MARK: - `Velum --google-sign-in <email>` and friends

/// Debug commands, run from Terminal with the app's own bundle (`build/Velum.app/Contents/MacOS/Velum`), so
/// the sign-in can be tested without replacing the running app:
/// - `--google-sign-in <email>` signs in (consent opens in the browser), turns the switch on, prints storage;
/// - `--google-storage <email>` fetches storage now with the saved sign-in;
/// - `--google-sign-out <email>` turns it off (revokes, deletes the Keychain item, clears the switch).
enum GoogleSignInDebug {
    static let commands = ["--google-sign-in", "--google-storage", "--google-sign-out"]

    @MainActor
    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(where: commands.contains), i + 1 < args.count else { return }
        let command = args[i]
        let email = args[i + 1]
        let shared = GoogleSignInStorage.shared
        guard shared.isAvailable else {
            print("This build has no Google OAuth client (Resources/GoogleOAuthClient.plist). See the README.")
            exit(1)
        }
        var status: Int32 = 0
        var done = false
        Task {
            do {
                switch command {
                case "--google-sign-in":
                    print("Opening Google's consent page in your browser for \(email)…")
                    let about = try await shared.signIn(email) { url in
                        print("If it doesn't open, visit:\n\(url.absoluteString)")
                        NSWorkspace.shared.open(url)
                    }
                    print("Signed in to Google as \(about.email ?? "(no email returned)").")
                    report(shared, email)
                case "--google-storage":
                    guard shared.isOn(email) else {
                        print("Google sign-in is off for \(email).")
                        status = 1
                        break
                    }
                    await shared.fetch(email)
                    report(shared, email)
                default:
                    await shared.turnOff(email)
                    print("Google sign-in is off for \(email): grant revoked, Keychain item deleted.")
                }
            } catch {
                print("Google sign-in failed: \(error)")
                status = 1
            }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        exit(status)
    }

    private static func report(_ shared: GoogleSignInStorage, _ email: String) {
        if let note = shared.note(for: email) { print("Note: \(note)") }
        // Peek without starting another fetch.
        guard let storage = shared.peek(email) else {
            print("No storage figures.")
            return
        }
        let bytes = { (n: Int64) in ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        print("Storage: \(bytes(storage.used)) used of \(storage.limit.map(bytes) ?? "unlimited")"
              + (storage.usedInDrive.map { " (Drive \(bytes($0)))" } ?? "")
              + " · exact: used \(storage.used), limit \(storage.limit.map(String.init) ?? "none"), in Drive \(storage.usedInDrive.map(String.init) ?? "-")")
    }
}

extension GoogleSignInStorage {
    /// The cached figures, without scheduling a fetch (for the debug commands and tests).
    func peek(_ email: String) -> GoogleStorage? {
        lock.withLock {
            let account = accounts[Self.key(email)]
            return account?.problem == nil ? account?.storage : nil
        }
    }
}
