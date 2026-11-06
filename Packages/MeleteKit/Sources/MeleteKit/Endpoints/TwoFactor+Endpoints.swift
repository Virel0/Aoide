import Foundation

/// Turning the signed-in user's two-factor sign-in on and off. Signing in with
/// it is in `Auth+Endpoints.swift`.
///
/// A wrong password or code is `.wrong(.password)` or `.wrong(.code)`; too
/// many of them lock these calls for 15 minutes (HTTP 429). Nothing here signs
/// anyone out.
extension MeleteClient {
    /// Whether it's on, since when, and the latest changes, newest first.
    public func twoFactorStatus() async throws -> TwoFactorStatus {
        try await get(path: "api/v1/me/two-factor")
    }

    /// Starts setting it up: a new secret for an authenticator app, which
    /// changes nothing until ``confirmTwoFactor(code:)``. HTTP 409 when it's on
    /// already. The secret is the account's second key: show it, never keep it.
    public func startTwoFactor(password: String) async throws -> TwoFactorSetup {
        struct Body: Encodable { let password: String }
        return try await post(path: "api/v1/me/two-factor/setup", body: Body(password: password))
    }

    /// Turns it on with a first code from the secret setup gave. HTTP 409 with
    /// no setup waiting (start again), or when it's on already.
    public func confirmTwoFactor(code: String) async throws {
        struct Body: Encodable { let code: String }
        try await sendIgnoringResponse("POST", path: "api/v1/me/two-factor/confirm", body: Body(code: Self.plain(code)))
    }

    /// Turns it off, with the password and a current code. HTTP 409 when it's
    /// off already.
    public func turnOffTwoFactor(password: String, code: String) async throws {
        struct Body: Encodable { let password: String; let code: String }
        try await sendIgnoringResponse(
            "POST",
            path: "api/v1/me/two-factor/off",
            body: Body(password: password, code: Self.plain(code))
        )
    }

    /// A code as typed or pasted (`123 456`), as the server reads it.
    static func plain(_ code: String) -> String {
        code.filter { !$0.isWhitespace }
    }
}
