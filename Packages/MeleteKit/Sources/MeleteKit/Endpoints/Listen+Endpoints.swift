import Foundation

extension MeleteClient {
    // MARK: - Listening together

    /// The sessions this device is in.
    public func listeningSessions() async throws -> [ListenSession] {
        try await get(path: "api/v1/music/sessions")
    }

    /// Starts a session playing `state`, with this device in it.
    public func startListening(_ state: ListenState) async throws -> Listening {
        try await post(path: "api/v1/music/sessions", body: state)
    }

    /// Joins the session with this code (any case, a space or dash allowed).
    /// `.notFound` when no session has it; 429 after five wrong codes.
    public func joinListening(code: String) async throws -> Listening {
        struct Body: Encodable { let code: String }
        return try await post(path: "api/v1/music/sessions/join", body: Body(code: code))
    }

    /// One session this device is in, as it is now; `.notFound` once it has
    /// ended or this device left it.
    public func listening(id: Int64) async throws -> Listening {
        try await get(path: "api/v1/music/sessions/\(id)")
    }

    /// Sets what plays, made against `version`. A session changed since is
    /// refused with 409 (``MeleteError/isStale``).
    public func changeListening(id: Int64, version: Int64, state: ListenState) async throws -> Listening {
        struct Body: Encodable {
            let version: Int64
            let queue: [Int64]
            let index: Int
            let positionMs: Int64
            let playing: Bool
        }
        let path = "api/v1/music/sessions/\(id)"
        let body = Body(
            version: version, queue: state.queue, index: state.index,
            positionMs: state.positionMs, playing: state.playing
        )
        let data = try await send(try jsonRequest("PUT", path: path, body: body), path: path)
        return try decode(Listening.self, from: data, path: path)
    }

    /// Leaves a session; the last to leave ends it.
    public func leaveListening(id: Int64) async throws {
        try await sendIgnoringResponse("POST", path: "api/v1/music/sessions/\(id)/leave")
    }

    /// Ends a session for everyone in it: for whoever started it, or an admin.
    public func endListening(id: Int64) async throws {
        try await sendIgnoringResponse("DELETE", path: "api/v1/music/sessions/\(id)")
    }
}

extension MeleteError {
    /// A change refused for being made against an old version.
    public var isStale: Bool {
        if case .http(status: 409, _, _) = self { return true }
        return false
    }
}
