import CryptoKit
import Darwin
import Foundation

// The optional Google sign-in: Google's OAuth flow for installed apps, opened in the user's default browser.
// - Redirect to a loopback port on 127.0.0.1 picked by macOS, with PKCE (S256).
// - One scope, `drive.file`: non-sensitive, needs no Google review, and doesn't let Velum see the user's
//   files. Under it, Drive's `about.get` still answers with the account's email and storage quota.
// - Google requires the client secret even with PKCE. For installed apps it isn't treated as a secret; it
//   comes from `GoogleOAuthClient.plist`, which stays out of git (see the README).
// Nothing here runs unless the user turns the sign-in on for an account (see GoogleSignInStorage).

/// The Desktop OAuth client Velum signs in with. nil from `load` when this build has none.
struct GoogleOAuthClient: Equatable, Sendable {
    let id: String
    let secret: String

    static let resourceName = "GoogleOAuthClient"

    static func load(from bundle: Bundle = .main) -> GoogleOAuthClient? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist") else { return nil }
        return load(contentsOf: url)
    }

    static func load(contentsOf url: URL) -> GoogleOAuthClient? {
        guard let dict = NSDictionary(contentsOf: url),
              let id = (dict["ClientID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = (dict["ClientSecret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !secret.isEmpty else { return nil }
        return GoogleOAuthClient(id: id, secret: secret)
    }
}

enum GoogleEndpoint {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let authorize = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let token = URL(string: "https://oauth2.googleapis.com/token")!
    static let revoke = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let about = URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(emailAddress),storageQuota")!
}

enum GoogleSignInError: Error, Equatable {
    /// Google answered `invalid_grant`: the sign-in expired or was revoked (in Google's settings, by a
    /// password change, or by Velum's own Turn Off). Only signing in again helps.
    case signInExpired
    /// The user declined in the browser.
    case denied
    /// No answer from the browser in time, or the sign-in was cancelled.
    case cancelled
    /// Google answered, but not with what the flow needs.
    case unexpected(String)
    /// An HTTP status other than 200 (401 from the Drive API means the access token went stale).
    case http(Int)
}

/// Sends a request and returns the body and HTTP status. The live one is `URLSession`; tests stub it.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionTransport: HTTPTransport {
    /// Ephemeral: no cookies or cache on disk. Created on first use, so a Velum that never signs in never
    /// makes a session.
    private static let session = URLSession(configuration: .ephemeral)

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// PKCE's verifier and its S256 challenge (RFC 7636).
struct PKCE: Equatable {
    let verifier: String
    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    let method = "S256"

    init(verifier: String = PKCE.randomString(bytes: 32)) {
        self.verifier = verifier
    }

    static func randomString(bytes: Int) -> String {
        var data = Data(count: bytes)
        let ok = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        precondition(ok == errSecSuccess, "no system randomness")
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct GoogleTokens: Equatable {
    var access: String
    var expires: Date
    /// Only in the first exchange (with `access_type=offline` and `prompt=consent`), never in a refresh.
    var refresh: String?
}

/// What Drive's `about.get` says about the signed-in account.
struct GoogleAbout: Equatable {
    var email: String?
    var storage: GoogleStorage?
}

/// The OAuth and Drive API calls, over a transport tests can stub.
struct GoogleAuth: Sendable {
    let client: GoogleOAuthClient
    var transport: HTTPTransport = URLSessionTransport()

    func authorizationURL(redirect: String, pkce: PKCE, state: String, loginHint: String) -> URL {
        var parts = URLComponents(url: GoogleEndpoint.authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleEndpoint.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "login_hint", value: loginHint),
        ]
        return parts.url!
    }

    func exchange(code: String, redirect: String, pkce: PKCE, now: Date) async throws -> GoogleTokens {
        try await tokenRequest([
            "code": code,
            "client_id": client.id,
            "client_secret": client.secret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": pkce.verifier,
        ], now: now)
    }

    func refresh(_ refreshToken: String, now: Date) async throws -> GoogleTokens {
        try await tokenRequest([
            "refresh_token": refreshToken,
            "client_id": client.id,
            "client_secret": client.secret,
            "grant_type": "refresh_token",
        ], now: now)
    }

    /// Best effort: an offline Mac leaves the grant at Google, where the user can remove it in their Google
    /// Account's third-party access page.
    @discardableResult
    func revoke(_ token: String) async -> Bool {
        let request = Self.form(GoogleEndpoint.revoke, ["token": token])
        guard let (_, status) = try? await transport.send(request) else { return false }
        return status == 200
    }

    func about(accessToken: String, now: Date) async throws -> GoogleAbout {
        var request = URLRequest(url: GoogleEndpoint.about, timeoutInterval: 30)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, status) = try await transport.send(request)
        guard status == 200 else { throw GoogleSignInError.http(status) }
        return try Self.parseAbout(data, now: now)
    }

    private func tokenRequest(_ fields: [String: String], now: Date) async throws -> GoogleTokens {
        let (data, status) = try await transport.send(Self.form(GoogleEndpoint.token, fields))
        return try Self.parseTokens(data, status: status, now: now)
    }

    static func form(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Form encoding: only unreserved characters stay as they are.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }

    static func parseTokens(_ data: Data, status: Int, now: Date) throws -> GoogleTokens {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? String {
            if error == "invalid_grant" { throw GoogleSignInError.signInExpired }
            throw GoogleSignInError.unexpected(error)
        }
        guard status == 200 else { throw GoogleSignInError.http(status) }
        guard let access = json["access_token"] as? String, !access.isEmpty else {
            throw GoogleSignInError.unexpected("no access token")
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return GoogleTokens(access: access, expires: now.addingTimeInterval(lifetime),
                            refresh: (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// `storageQuota`'s numbers arrive as strings (int64 in JSON). No `limit` means an unlimited plan.
    static func parseAbout(_ data: Data, now: Date) throws -> GoogleAbout {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GoogleSignInError.unexpected("about isn't JSON")
        }
        let email = (json["user"] as? [String: Any])?["emailAddress"] as? String
        func number(_ value: Any?) -> Int64? {
            if let s = value as? String { return Int64(s) }
            return (value as? NSNumber)?.int64Value
        }
        var storage: GoogleStorage?
        if let quota = json["storageQuota"] as? [String: Any], let used = number(quota["usage"]) {
            storage = GoogleStorage(limit: number(quota["limit"]), used: used, usedInDrive: number(quota["usageInDrive"]),
                                    source: .googleSignIn, asOf: now)
        }
        return GoogleAbout(email: email, storage: storage)
    }

    /// The whole sign-in: opens Google's consent page in the browser, waits for its redirect on a loopback
    /// port, and trades the code for tokens. `open` shows the page (the default browser, in the app).
    func signIn(loginHint: String, receiver: LoopbackReceiver, open: (URL) -> Void, now: @escaping () -> Date,
                timeout: TimeInterval = 300) async throws -> (GoogleTokens, GoogleAbout) {
        let pkce = PKCE()
        let state = PKCE.randomString(bytes: 16)
        let redirect = receiver.redirectURI
        open(authorizationURL(redirect: redirect, pkce: pkce, state: state, loginHint: loginHint))
        let code = try await receiver.waitForCode(state: state, deadline: now().addingTimeInterval(timeout))
        let tokens = try await exchange(code: code, redirect: redirect, pkce: pkce, now: now())
        guard tokens.refresh != nil else { throw GoogleSignInError.unexpected("no refresh token") }
        return (tokens, try await about(accessToken: tokens.access, now: now()))
    }
}

/// Listens on 127.0.0.1, at a port macOS picks, for the one request Google's consent page redirects the
/// browser to. Loopback only: nothing off this Mac can reach it, and it closes as soon as the code arrives.
final class LoopbackReceiver: @unchecked Sendable {
    let port: UInt16
    private let socket: Int32
    private let lock = NSLock()
    private var cancelled = false

    var redirectURI: String { "http://127.0.0.1:\(port)" }

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GoogleSignInError.unexpected("no socket") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                   // any free port
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            throw GoogleSignInError.unexpected("can't listen on 127.0.0.1")
        }
        socket = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(socket) }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Waits for Google's redirect and returns its code. Other requests (a browser's favicon) get a 404.
    func waitForCode(state: String, deadline: Date) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.acceptCode(state: state, deadline: deadline) })
            }
        }
    }

    private func acceptCode(state: String, deadline: Date) throws -> String {
        while true {
            if lock.withLock({ cancelled }) || Date() > deadline { throw GoogleSignInError.cancelled }
            var waiting = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 500) > 0 else { continue }
            let client = accept(socket, nil, nil)
            guard client >= 0 else { continue }
            defer { close(client) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var nosigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

            let request = Self.readRequestHead(client)
            switch Self.parseRedirect(request, state: state) {
            case .code(let code):
                Self.respond(client, status: "200 OK", page: Self.page(
                    "Velum is signed in to Google",
                    "Velum can now show this account’s storage. You can close this tab."))
                return code
            case .denied:
                Self.respond(client, status: "200 OK", page: Self.page(
                    "Velum didn’t get access",
                    "Nothing changed. You can close this tab, and try again from Velum’s menu."))
                throw GoogleSignInError.denied
            case .other:
                Self.respond(client, status: "404 Not Found", page: "")
            }
        }
    }

    enum Redirect: Equatable { case code(String), denied, other }

    /// Reads the request line of Google's redirect (`GET /?state=…&code=… HTTP/1.1`). The state must match
    /// the one this sign-in sent, so no other page can hand Velum a code.
    static func parseRedirect(_ request: String, state: String) -> Redirect {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let items = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems else { return .other }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { return .other }
        if let code = value("code"), !code.isEmpty { return .code(code) }
        if value("error") != nil { return .denied }
        return .other
    }

    private static func readRequestHead(_ fd: Int32) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16_384 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func respond(_ fd: Int32, status: String, page: String) {
        let body = Data(page.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let message = Data(head.utf8) + body
        message.withUnsafeBytes { _ = write(fd, $0.baseAddress, message.count) }
    }

    private static func page(_ title: String, _ text: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;padding:0 1em;color:#222}
        @media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}h1{font-size:20px}</style></head>
        <body><h1>\(title)</h1><p>\(text)</p></body></html>
        """
    }
}
