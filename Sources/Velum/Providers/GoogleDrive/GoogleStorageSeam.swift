import Foundation

// TEMPORARY: the seam the main session is adding to GoogleDriveProvider.swift on `main`. Declared here, in
// identical form, until that lands; delete this file when `main` is merged into this branch.

/// Storage for one Google account (shared by Drive, Gmail and Photos).
struct GoogleStorage: Equatable {
    var limit: Int64?          // nil = unlimited plan
    var used: Int64            // whole account
    var usedInDrive: Int64?
    var source: Source
    var asOf: Date
    enum Source: Equatable { case driveCache, googleSignIn }
}
extension GoogleDriveProvider {
    /// Storage from the optional Google sign-in, for accounts whose Drive cache has none. Called on the
    /// collector's queue every refresh: return cached figures, never block.
    nonisolated(unsafe) static var signInStorage: (_ email: String) -> GoogleStorage? = { _ in nil }
    /// A short note from the optional Google sign-in for this account ("Sign in to Google again…"), or nil.
    /// Same rules as `signInStorage`.
    nonisolated(unsafe) static var signInNote: (_ email: String) -> String? = { _ in nil }
}
