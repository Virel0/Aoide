import Foundation

/// A library track the sidecar chose for an imported one, with its reasons.
public struct SidecarMatch: Decodable, Equatable, Sendable {
    public let jellyfinId: String
    public let confidence: Double
    public let titleScore: Double
    public let artistScore: Double
    public let durationScore: Double
    public let title: String?
    public let artists: [String]?
    public let album: String?
    public let durationMs: Int?
}

struct SidecarMatchResponse: Decodable {
    let results: [SidecarMatch?]
    let matched: Int
    let librarySize: Int
}

/// The wire form of an imported track, spelled the way the sidecar reads it.
struct ImportedTrackBody: Encodable {
    let title: String
    let artists: [String]
    let album: String?
    let durationMs: Int?
    let isrc: String?

    init(_ track: ImportedTrack) {
        title = track.title
        artists = track.artists
        album = track.album
        durationMs = track.durationMs
        isrc = track.isrc
    }
}

extension MeleteClient {
    /// `POST /aoide/match`: the sidecar's answer for each imported track, or nil
    /// where the library has nothing for it.
    ///
    /// One request instead of several per track. The sidecar carries the same
    /// matching rules as `TrackMatcher` and is checked against the same table of
    /// cases, so it answers as this device would — only from inside the library,
    /// where a thousand rows is a lookup rather than a thousand round trips.
    /// Throws when the sidecar is absent or fails; the caller matches locally then.
    public func match(_ tracks: [ImportedTrack]) async throws -> [SidecarMatch?] {
        var results: [SidecarMatch?] = []
        results.reserveCapacity(tracks.count)
        for start in stride(from: 0, to: tracks.count, by: Self.matchRowsPerRequest) {
            let slice = Array(tracks[start..<min(start + Self.matchRowsPerRequest, tracks.count)])
            var request = request("POST", path: Self.matchPath)
            request.httpBody = try Self.matchBody(slice)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let data = try await send(request, path: Self.matchPath)
            let response = try JSONDecoder().decode(SidecarMatchResponse.self, from: data)
            results.append(contentsOf: response.results)
        }
        return results
    }

    /// The sidecar refuses more than this many rows in one call.
    static let matchRowsPerRequest = 5000
    static var matchPath: String { "aoide/match" }

    /// Split out so the body can be asserted without a server.
    static func matchBody(_ tracks: [ImportedTrack]) throws -> Data {
        try JSONEncoder().encode(tracks.map(ImportedTrackBody.init))
    }
}
