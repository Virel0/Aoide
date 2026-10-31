import Foundation

extension MeleteClient {
    // MARK: - Requests

    /// Artists, albums or songs on MusicBrainz matching `words`, best first (20 at
    /// most), each marked in the library, wanted, or asked for already. HTTP 409
    /// when the server has MusicBrainz off; 502 when MusicBrainz didn't answer.
    public func requestSearch(_ kind: RequestKind, words: String) async throws -> [RequestCandidate] {
        try await get(path: "api/v1/requests/search", query: [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "q", value: words.trimmingCharacters(in: .whitespaces)),
        ])
    }

    /// Asks for `candidate`: approved at once for an admin, or a user whose
    /// requests go straight through; otherwise it waits for an admin. HTTP 409 when
    /// it's been asked for already.
    public func askFor(_ candidate: RequestCandidate) async throws -> MusicRequest {
        // Only the id of its own kind: another kind's is refused.
        var body: [String: String?] = ["kind": candidate.kind.rawValue]
        switch candidate.kind {
        case .artist: body["mb_artist_id"] = candidate.mbArtistId
        case .album: body["mb_release_group_id"] = candidate.mbReleaseGroupId
        case .song, .other: body["mb_recording_id"] = candidate.mbRecordingId
        }
        let path = "api/v1/requests"
        var request = request("POST", path: path)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try await send(request, path: path)
        return try decode(MusicRequest.self, from: data, path: path)
    }

    /// This user's music requests, newest first (the latest 200).
    public func musicRequests() async throws -> [MusicRequest] {
        struct Page: Decodable { let items: [MusicRequest] }
        let page: Page = try await get(path: "api/v1/requests", query: [
            URLQueryItem(name: "limit", value: "200"),
            URLQueryItem(name: "service", value: "music"),
        ])
        return page.items
    }

    /// Takes back a request still waiting for an admin; HTTP 409 once it's decided.
    public func withdrawRequest(id: Int64) async throws {
        try await sendIgnoringResponse("DELETE", path: "api/v1/requests/\(id)")
    }
}
