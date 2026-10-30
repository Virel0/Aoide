import Foundation

/// What Melete's Home view has, worked out on the server from this listener's
/// history on every device.
public struct MusicHome: Sendable {
    /// Albums played lately, newest first.
    public let recentlyPlayed: [MusicItem]
    /// The tracks played most in the last 30 days, with how many times.
    public let mostPlayed: [(track: MusicItem, plays: Int)]
    /// Albums added lately, newest first.
    public let recentlyAdded: [MusicItem]
}

extension MeleteClient {
    // MARK: - Home

    public func home() async throws -> MusicHome {
        struct Wire: Decodable {
            struct MostPlayed: Decodable {
                let plays: Int
                let track: WireTrack
            }
            let recentlyPlayed: [WireAlbum]
            let mostPlayed: [MostPlayed]
            let recentlyAdded: [WireAlbum]
        }
        let home: Wire = try await get(path: "api/v1/music/home")
        return MusicHome(
            recentlyPlayed: home.recentlyPlayed.map(\.item),
            mostPlayed: home.mostPlayed.map { ($0.track.item, $0.plays) },
            recentlyAdded: home.recentlyAdded.map(\.item)
        )
    }

    // MARK: - Likes

    /// The tracks the signed-in user likes, newest like first; a liked track gone
    /// from the library is left out.
    public func likedTracks() async throws -> [MusicItem] {
        struct Wire: Decodable {
            struct Like: Decodable { let track: WireTrack? }
            let tracks: [Like]
        }
        let likes: Wire = try await get(path: "api/v1/music/likes")
        return likes.tracks.compactMap { $0.track?.item }
    }

    /// Likes or unlikes a track, written into the user's sync log as one of
    /// their devices would; the local store sees it on its next pull.
    public func setLiked(_ liked: Bool, trackId: String) async throws {
        try await sendIgnoringResponse(liked ? "PUT" : "DELETE", path: "api/v1/music/tracks/\(trackId)/like")
    }
}
