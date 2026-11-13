import Foundation
import Testing
@testable import Velum

/// The optional Google sign-in, with a stubbed network, an in-memory Keychain and a private UserDefaults.
/// Made-up accounts only.
@Suite struct GoogleSignIn {
    static let email = "someone.else@example.com"
    static let client = GoogleOAuthClient(id: "test-client.apps.googleusercontent.com", secret: "test-secret")

    /// Records every request and answers from `handler`.
    final class StubTransport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [URLRequest] = []
        var handler: (URLRequest) -> (Data, Int)

        init(_ handler: @escaping (URLRequest) -> (Data, Int) = { _ in (Data(), 500) }) { self.handler = handler }

        var requests: [URLRequest] { lock.withLock { sent } }

        func send(_ request: URLRequest) async throws -> (Data, Int) {
            lock.withLock { sent.append(request) }
            return handler(request)
        }
    }

    final class MemoryTokens: TokenStore {
        var items: [String: String] = [:]
        var reads = 0
        func read(_ account: String) -> String? { reads += 1; return items[account] }
        func write(_ token: String, for account: String) throws { items[account] = token }
        func delete(_ account: String) { items[account] = nil }
    }

    final class Clock: @unchecked Sendable {
        var now = Fixture.now
    }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    static func form(_ request: URLRequest) -> [String: String] {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1).map(String.init)
            return (pair[0], pair.count > 1 ? (pair[1].removingPercentEncoding ?? "") : "")
        })
    }

    static let aboutWithLimit = json(["user": ["emailAddress": email],
                                      "storageQuota": ["limit": "16106127360", "usage": "5368709120",
                                                       "usageInDrive": "1073741824", "usageInDriveTrash": "0"]])

    /// A Google that refreshes tokens and answers `about` like a 15 GB account.
    static func google(about: Data = aboutWithLimit) -> StubTransport {
        StubTransport { request in
            if request.url == GoogleEndpoint.token { return (json(["access_token": "fresh-access", "expires_in": 3599]), 200) }
            if request.url == GoogleEndpoint.about { return (about, 200) }
            return (Data(), 200)
        }
    }

    static func make(_ transport: StubTransport, tokens: MemoryTokens = MemoryTokens(), clock: Clock = Clock(),
                     on: Bool = true) -> (GoogleSignInStorage, UserDefaults) {
        let defaults = UserDefaults(suiteName: "velum-tests-\(UUID().uuidString)")!
        if on { defaults.set([email], forKey: GoogleSignInStorage.defaultsKey) }
        if on && tokens.items.isEmpty { tokens.items[email] = "saved-refresh" }
        let storage = GoogleSignInStorage(client: client, transport: transport, defaults: defaults, tokens: tokens,
                                          now: { clock.now })
        return (storage, defaults)
    }

    // MARK: OAuth pieces

    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 43)
    }

    @Test func authorizationURLAsksForDriveFileOnly() {
        let auth = GoogleAuth(client: Self.client, transport: StubTransport())
        let url = auth.authorizationURL(redirect: "http://127.0.0.1:5555", pkce: PKCE(verifier: "v"), state: "s",
                                        loginHint: Self.email)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.google.com")
        #expect(items["scope"] == "https://www.googleapis.com/auth/drive.file")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5555")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == PKCE(verifier: "v").challenge)
        #expect(items["access_type"] == "offline")
        #expect(items["prompt"] == "consent")
        #expect(items["login_hint"] == Self.email)
        #expect(items["state"] == "s")
        #expect(items["client_secret"] == nil)   // never in the browser
    }

    @Test func exchangeSendsVerifierAndSecret() async throws {
        let google = StubTransport { _ in
            (Self.json(["access_token": "a1", "expires_in": 3599, "refresh_token": "r1", "token_type": "Bearer"]), 200)
        }
        let auth = GoogleAuth(client: Self.client, transport: google)
        let tokens = try await auth.exchange(code: "4/code+with/slash", redirect: "http://127.0.0.1:5555",
                                             pkce: PKCE(verifier: "verifier"), now: Fixture.now)
        #expect(tokens == GoogleTokens(access: "a1", expires: Fixture.now.addingTimeInterval(3599), refresh: "r1"))
        let request = try #require(google.requests.first)
        #expect(request.url == GoogleEndpoint.token)
        #expect(request.httpMethod == "POST")
        let form = Self.form(request)
        #expect(form["code"] == "4/code+with/slash")
        #expect(form["code_verifier"] == "verifier")
        #expect(form["client_secret"] == "test-secret")
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["redirect_uri"] == "http://127.0.0.1:5555")
    }

    @Test func invalidGrantMeansSignInAgain() async {
        let google = StubTransport { _ in
            (Self.json(["error": "invalid_grant", "error_description": "Token has been expired or revoked."]), 400)
        }
        let auth = GoogleAuth(client: Self.client, transport: google)
        await #expect(throws: GoogleSignInError.signInExpired) {
            try await auth.refresh("dead", now: Fixture.now)
        }
    }

    @Test func redirectNeedsTheRightState() {
        let ok = "GET /?state=abc&code=4/xyz&scope=https://www.googleapis.com/auth/drive.file HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        #expect(LoopbackReceiver.parseRedirect(ok, state: "abc") == .code("4/xyz"))
        #expect(LoopbackReceiver.parseRedirect(ok, state: "other") == .other)
        #expect(LoopbackReceiver.parseRedirect("GET /?state=abc&error=access_denied HTTP/1.1\r\n\r\n", state: "abc") == .denied)
        #expect(LoopbackReceiver.parseRedirect("GET /favicon.ico HTTP/1.1\r\n\r\n", state: "abc") == .other)
    }

    @Test func loopbackReceivesTheRedirect() async throws {
        let receiver = try LoopbackReceiver()
        #expect(receiver.redirectURI.hasPrefix("http://127.0.0.1:"))
        let waiting = Task { try await receiver.waitForCode(state: "s1", deadline: Date().addingTimeInterval(20)) }
        let session = URLSession(configuration: .ephemeral)
        let (_, favicon) = try await session.data(from: URL(string: receiver.redirectURI + "/favicon.ico")!)
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)
        let (page, response) = try await session.data(from: URL(string: receiver.redirectURI + "/?state=s1&code=the-code")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: page, as: UTF8.self).contains("signed in"))
        #expect(try await waiting.value == "the-code")
    }

    @Test func loopbackCanBeCancelled() async throws {
        let receiver = try LoopbackReceiver()
        let waiting = Task { try await receiver.waitForCode(state: "s", deadline: Date().addingTimeInterval(20)) }
        receiver.cancel()
        await #expect(throws: GoogleSignInError.cancelled) { try await waiting.value }
    }

    // MARK: The whole sign-in, with the test playing the browser

    /// Follows Google's redirect back to Velum's loopback port with a code, as the browser would after Allow.
    static func browser(code: String = "4/the-code") -> (URL) -> Void {
        { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = items.first { $0.name == "redirect_uri" }!.value!
            let state = items.first { $0.name == "state" }!.value!
            Task.detached {
                _ = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "\(redirect)/?state=\(state)&code=\(code)")!)
            }
        }
    }

    /// A Google whose token endpoint hands out a new grant, and whose `about` answers with `about`.
    static func consentingGoogle(about: Data = aboutWithLimit) -> StubTransport {
        StubTransport { request in
            if request.url == GoogleEndpoint.token {
                return (json(["access_token": "new-access", "expires_in": 3599, "refresh_token": "new-refresh"]), 200)
            }
            if request.url == GoogleEndpoint.about { return (about, 200) }
            return (Data(), 200)
        }
    }

    @Test func signingInTurnsItOnAndKeepsTheToken() async throws {
        let google = Self.consentingGoogle()
        let tokens = MemoryTokens()
        let (storage, defaults) = Self.make(google, tokens: tokens, on: false)
        let about = try await storage.signIn(Self.email, open: Self.browser())
        #expect(about.email == Self.email)
        #expect(tokens.items[Self.email] == "new-refresh")
        #expect(defaults.stringArray(forKey: GoogleSignInStorage.defaultsKey) == [Self.email])
        #expect(storage.phase(for: Self.email) == .on)
        #expect(storage.peek(Self.email)?.used == 5_368_709_120)
        let exchange = Self.form(google.requests[0])
        #expect(exchange["code"] == "4/the-code")
        #expect(exchange["grant_type"] == "authorization_code")
        #expect(exchange["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(google.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    }

    @Test func aSignInAsAnotherAccountIsDiscarded() async {
        let other = Self.json(["user": ["emailAddress": "somebody.different@example.com"], "storageQuota": ["usage": "1"]])
        let google = Self.consentingGoogle(about: other)
        let tokens = MemoryTokens()
        let (storage, defaults) = Self.make(google, tokens: tokens, on: false)
        await #expect(throws: GoogleSignInError.otherAccount("somebody.different@example.com")) {
            try await storage.signIn(Self.email, open: Self.browser())
        }
        #expect(tokens.items.isEmpty)
        #expect(defaults.stringArray(forKey: GoogleSignInStorage.defaultsKey) == nil)
        #expect(storage.phase(for: Self.email) == .off)
        #expect(storage.peek(Self.email) == nil)
        let revoke = google.requests.last
        #expect(revoke?.url == GoogleEndpoint.revoke)                  // the stray grant doesn't linger at Google
        #expect(revoke.map(Self.form)?["token"] == "new-refresh")
    }

    // MARK: Quota

    @Test func quotaWithALimit() throws {
        let about = try GoogleAuth.parseAbout(Self.aboutWithLimit, now: Fixture.now)
        #expect(about.email == Self.email)
        #expect(about.storage == GoogleStorage(limit: 16_106_127_360, used: 5_368_709_120, usedInDrive: 1_073_741_824,
                                               source: .googleSignIn, asOf: Fixture.now))
    }

    @Test func quotaWithoutALimitIsUnlimited() throws {
        let data = Self.json(["user": ["emailAddress": Self.email],
                              "storageQuota": ["usage": "123456789012", "usageInDrive": "100"]])
        let storage = try #require(try GoogleAuth.parseAbout(data, now: Fixture.now).storage)
        #expect(storage.limit == nil)
        #expect(storage.used == 123_456_789_012)
        #expect(storage.usedInDrive == 100)
    }

    @Test func noQuotaNoFigures() throws {
        let about = try GoogleAuth.parseAbout(Self.json(["user": ["emailAddress": Self.email]]), now: Fixture.now)
        #expect(about.storage == nil)
    }

    // MARK: The per-account switch

    @Test func offMakesNoRequest() async throws {
        let google = Self.google()
        let tokens = MemoryTokens()
        tokens.items[Self.email] = "left-behind"
        let (storage, _) = Self.make(google, tokens: tokens, on: false)
        #expect(storage.storage(for: Self.email) == nil)
        #expect(storage.note(for: Self.email) == nil)
        #expect(storage.phase(for: Self.email) == .off)
        try await Task.sleep(for: .milliseconds(200))
        #expect(google.requests.isEmpty)
        #expect(tokens.reads == 0)             // no Keychain reads while off
    }

    @Test func aBuildWithoutAClientOffersNothing() {
        let google = Self.google()
        let defaults = UserDefaults(suiteName: "velum-tests-\(UUID().uuidString)")!
        defaults.set([Self.email], forKey: GoogleSignInStorage.defaultsKey)
        let storage = GoogleSignInStorage(client: nil, transport: google, defaults: defaults, tokens: MemoryTokens())
        #expect(!storage.isAvailable)
        #expect(storage.phase(for: Self.email) == .unavailable)
        #expect(storage.storage(for: Self.email) == nil)
        #expect(google.requests.isEmpty)
    }

    @Test func onFetchesInTheBackgroundThenServesFromCache() async throws {
        let google = Self.google()
        let clock = Clock()
        let (storage, _) = Self.make(google, clock: clock)
        #expect(storage.storage(for: Self.email.uppercased()) == nil)    // nothing yet; a fetch starts
        for _ in 0..<100 where storage.peek(Self.email) == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(storage.storage(for: Self.email)?.used == 5_368_709_120)
        // Refresh token from the Keychain, then about with the fresh access token.
        #expect(google.requests.map(\.url) == [GoogleEndpoint.token, GoogleEndpoint.about])
        #expect(Self.form(google.requests[0])["refresh_token"] == "saved-refresh")
        #expect(google.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fresh-access")

        // Within 30 minutes, every refresh is served from memory.
        clock.now += 29 * 60
        _ = storage.storage(for: Self.email)
        try await Task.sleep(for: .milliseconds(100))
        #expect(google.requests.count == 2)

        // The panel opening makes figures older than 5 minutes due; the access token is still good.
        storage.panelOpened()
        _ = storage.storage(for: Self.email)
        for _ in 0..<100 where google.requests.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(google.requests.map(\.url).last == GoogleEndpoint.about)
        #expect(google.requests.count == 3)
    }

    @Test func staleAccessTokenRefreshesOnceAndRetries() async {
        var aboutCalls = 0
        let google = StubTransport { request in
            if request.url == GoogleEndpoint.token { return (Self.json(["access_token": "fresh-access", "expires_in": 3599]), 200) }
            aboutCalls += 1
            return aboutCalls == 1 ? (Data(), 401) : (Self.aboutWithLimit, 200)
        }
        let (storage, _) = Self.make(google)
        await storage.fetch(Self.email)
        #expect(storage.peek(Self.email)?.limit == 16_106_127_360)
        #expect(google.requests.map(\.url) == [GoogleEndpoint.token, GoogleEndpoint.about, GoogleEndpoint.token, GoogleEndpoint.about])
    }

    @Test func revokedSignInAsksToSignInAgain() async {
        let google = StubTransport { _ in (Self.json(["error": "invalid_grant"]), 400) }
        let tokens = MemoryTokens()
        let (storage, _) = Self.make(google, tokens: tokens)
        await storage.fetch(Self.email)
        #expect(storage.phase(for: Self.email) == .expired)
        #expect(storage.note(for: Self.email)?.contains("sign in again") == true)
        #expect(storage.storage(for: Self.email) == nil)
        #expect(tokens.items.isEmpty)           // the dead token is gone
        // No retry loop: an expired sign-in waits for the user.
        let count = google.requests.count
        _ = storage.storage(for: Self.email)
        #expect(google.requests.count == count)
    }

    @Test func networkFailureKeepsTheLastFigures() async {
        let google = Self.google()
        let clock = Clock()
        let (storage, _) = Self.make(google, clock: clock)
        await storage.fetch(Self.email)
        google.handler = { _ in (Data(), 503) }
        clock.now += 31 * 60
        await storage.fetch(Self.email)
        #expect(storage.peek(Self.email)?.used == 5_368_709_120)
        #expect(storage.note(for: Self.email) == nil)
    }

    @Test func anotherAccountsSignInShowsANoteAndNoFigures() async {
        let other = Self.json(["user": ["emailAddress": "somebody.different@example.com"],
                               "storageQuota": ["limit": "100", "usage": "50"]])
        let (storage, _) = Self.make(Self.google(about: other))
        await storage.fetch(Self.email)
        #expect(storage.storage(for: Self.email) == nil)
        #expect(storage.peek(Self.email) == nil)
        #expect(storage.note(for: Self.email) == "Storage not shown · the Google sign-in is for somebody.different@example.com")
    }

    @Test func emailCaseDoesNotMatter() async {
        let shouty = Self.json(["user": ["emailAddress": "Someone.Else@Gmail.com"], "storageQuota": ["usage": "7"]])
        let (storage, _) = Self.make(Self.google(about: shouty))
        await storage.fetch(Self.email)
        #expect(storage.peek(Self.email)?.used == 7)
    }

    @Test func turningOffRevokesDeletesAndClears() async {
        let google = Self.google()
        let tokens = MemoryTokens()
        let (storage, defaults) = Self.make(google, tokens: tokens)
        await storage.fetch(Self.email)
        await storage.turnOff(Self.email)
        #expect(tokens.items.isEmpty)
        #expect(defaults.stringArray(forKey: GoogleSignInStorage.defaultsKey) == nil)
        #expect(storage.phase(for: Self.email) == .off)
        #expect(storage.peek(Self.email) == nil)
        let revoke = google.requests.last
        #expect(revoke?.url == GoogleEndpoint.revoke)
        #expect(revoke.map(Self.form)?["token"] == "saved-refresh")
    }

    @Test func menuAlwaysOffersAWayInAndOut() {
        func titles(_ phase: GoogleSignInStorage.Phase, _ lacking: Bool) -> [String] {
            GoogleSignInStorage.menuItems(phase: phase, cacheLacksFigures: lacking).map(\.title)
        }
        #expect(titles(.unavailable, true) == [])                       // no OAuth client in this build
        #expect(titles(.off, true) == ["Show Storage…"])
        #expect(titles(.off, false) == ["Sign In to Google for Storage…"])   // storage already shows from the cache
        #expect(titles(.signingIn, true) == ["Cancel Sign-In"])
        #expect(titles(.on, true) == ["Stop Showing Storage"])
        #expect(titles(.on, false) == ["Stop Showing Storage"])         // once on, the way off is always there
        #expect(titles(.expired, true) == ["Sign In Again…", "Stop Showing Storage"])
        #expect(GoogleSignInStorage.menuItems(phase: .off, cacheLacksFigures: true).map(\.on) == [true])
        #expect(GoogleSignInStorage.menuItems(phase: .on, cacheLacksFigures: true).map(\.on) == [false])
    }

    @Test func askingForANoteMeansTheCacheIsEmpty() {
        let clock = Clock()
        let (storage, _) = Self.make(Self.google(), clock: clock, on: false)
        #expect(!storage.cacheLacksFigures(Self.email))
        #expect(storage.note(for: Self.email) == nil)                  // off: no note, but the question counts
        #expect(storage.cacheLacksFigures(Self.email))
        clock.now += 60                                                 // the provider stopped asking: cache is back
        #expect(!storage.cacheLacksFigures(Self.email))
    }

    @Test func emailFromTheAccountKey() {
        let root = URL(fileURLWithPath: "/Users/test/Library/CloudStorage/GoogleDrive-\(Self.email)")
        #expect(GoogleSignInStorage.email(for: GoogleDriveProvider.config(email: Self.email, root: root)) == Self.email)
        #expect(GoogleSignInStorage.email(for: Fixture.oneDrive()) == nil)
    }

    @Test func clientFileNeedsBothKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "velum-oauth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appending(path: "good.plist")
        let half = dir.appending(path: "half.plist")
        try (["ClientID": "id ", "ClientSecret": "secret"] as NSDictionary).write(to: good)
        try (["ClientID": "id"] as NSDictionary).write(to: half)
        #expect(GoogleOAuthClient.load(contentsOf: good) == GoogleOAuthClient(id: "id", secret: "secret"))
        #expect(GoogleOAuthClient.load(contentsOf: half) == nil)
    }
}

/// The provider's side of the seam. Serialized: it sets the provider's shared closures.
@Suite(.serialized) struct GoogleSignInSeam {
    final class Counter: @unchecked Sendable { var storage = 0, notes = 0 }

    func withCountingSeam(_ body: (Counter) -> Void) {
        let counter = Counter()
        let figures = GoogleStorage(limit: 100, used: 1, usedInDrive: nil, source: .googleSignIn, asOf: Fixture.now)
        GoogleDriveProvider.signInStorage = { _ in counter.storage += 1; return figures }
        GoogleDriveProvider.signInNote = { _ in counter.notes += 1; return "a note" }
        defer {
            GoogleDriveProvider.signInStorage = { _ in nil }
            GoogleDriveProvider.signInNote = { _ in nil }
        }
        body(counter)
    }

    @Test func theCacheWinsWhenItHasFigures() {
        withCountingSeam { counter in
            let cached = GoogleStorage(limit: 400, used: 186, usedInDrive: nil, source: .driveCache, asOf: Fixture.now)
            let shown = GoogleDriveProvider.storage(cached: cached, email: "someone.else@example.com")
            #expect(shown.storage == cached)
            #expect(shown.signInNote == nil)
            #expect(counter.storage == 0 && counter.notes == 0)       // the sign-in is never asked
        }
    }

    @Test func theSignInFillsAnEmptyCache() {
        withCountingSeam { counter in
            let shown = GoogleDriveProvider.storage(cached: nil, email: "someone.else@example.com")
            #expect(shown.storage?.source == .googleSignIn)
            #expect(shown.signInNote == "a note")
            #expect(counter.storage == 1 && counter.notes == 1)
        }
    }
}
