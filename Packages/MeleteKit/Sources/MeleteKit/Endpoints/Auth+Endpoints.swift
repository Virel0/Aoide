import Foundation

extension MeleteClient {
    /// Confirms the address really is a Melete server, before a password goes
    /// anywhere.
    public func serverInfo() async throws -> ServerInfo {
        do {
            let info = try await get(ServerInfo.self, path: "api/v1/health")
            guard info.status == "ok" else { throw MeleteError.notAMeleteServer(serverURL) }
            return info
        } catch MeleteError.decoding, MeleteError.notFound {
            // Something answered, but it wasn't Melete — a router admin page, a
            // reverse proxy 404, another service on the port.
            throw MeleteError.notAMeleteServer(serverURL)
        }
    }

    /// Signs in with a username and password, as this client's device. A wrong
    /// password and an unknown username are both `.unauthorized`; five wrong tries
    /// lock the pair for 15 minutes (HTTP 429).
    public func signIn(username: String, password: String) async throws -> (MeleteCredentials, MeleteUser) {
        let session: Session = try await post(
            path: "api/v1/auth/login",
            body: LoginRequest(username: username, password: password, deviceName: device.signInName)
        )
        return credentials(for: session)
    }

    /// Starts Quick Connect: show the code, then ``pollQuickConnect(secret:)``
    /// every few seconds until someone approves it in Melete's web UI.
    public func startQuickConnect() async throws -> QuickConnectCode {
        struct Body: Encodable { let deviceName: String }
        return try await post(path: "api/v1/auth/quick-connect", body: Body(deviceName: device.signInName))
    }

    /// Asks once whether the code was approved: the session once it was (and only
    /// that once), `nil` while it waits. `.notFound` once the code ran out.
    public func pollQuickConnect(secret: String) async throws -> (MeleteCredentials, MeleteUser)? {
        struct Body: Encodable { let secret: String }
        let path = "api/v1/auth/quick-connect/poll"
        let (data, status) = try await sendWithStatus(
            try jsonRequest("POST", path: path, body: Body(secret: secret)),
            path: path
        )
        if status == 202 { return nil }
        return credentials(for: try decode(Session.self, from: data, path: path))
    }

    /// Ends the session on the server, which revokes the token.
    public func signOut() async throws {
        try await sendIgnoringResponse("POST", path: "api/v1/auth/logout")
    }

    /// Every user's name on the server, for choosing whom to share with. Any
    /// signed-in user may list them.
    public func userDirectory() async throws -> [MeleteUser] {
        try await get(path: "api/v1/users/directory")
    }

    private func credentials(for session: Session) -> (MeleteCredentials, MeleteUser) {
        let credentials = MeleteCredentials(
            serverURL: serverURL,
            userId: session.user.id,
            username: session.user.name,
            accessToken: session.token
        )
        return (credentials, session.user)
    }
}
