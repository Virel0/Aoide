import Foundation

extension JellyfinClient {
    /// Confirms the address really is a Jellyfin server before we ask for a password.
    /// Requires no auth, which is exactly why it's the right probe.
    public func systemInfo() async throws -> PublicSystemInfo {
        do {
            return try await get(PublicSystemInfo.self, path: "System/Info/Public")
        } catch JellyfinError.decoding, JellyfinError.notFound {
            // Something answered, but it wasn't Jellyfin — a router admin page, a
            // reverse proxy 404, another service on :8096.
            throw JellyfinError.notAJellyfinServer(serverURL)
        }
    }

    /// Signs in and returns credentials ready to be stored in the keychain.
    public func signIn(username: String, password: String) async throws -> (JellyfinCredentials, JellyfinUser) {
        let result: AuthenticationResult = try await post(
            path: "Users/AuthenticateByName",
            body: AuthenticateByNameRequest(username: username, pw: password)
        )
        let credentials = JellyfinCredentials(
            serverURL: serverURL,
            userId: result.user.id,
            username: result.user.name,
            accessToken: result.accessToken
        )
        return (credentials, result.user)
    }

    /// Best-effort server-side session teardown. The local credential wipe is what
    /// actually signs the user out, so callers should ignore failures here.
    public func signOut() async throws {
        try await postIgnoringResponse(path: "Sessions/Logout", body: Optional<Never>.none)
    }
}
