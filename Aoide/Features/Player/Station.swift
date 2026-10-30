import CurationKit
import MeleteKit

/// A station: the seed song (an album's or artist's first, when one of those
/// seeds it), then what Melete's `/aoide/next` would play after it — the same
/// choosing Infinity does — without the songs marked Not Interested.
///
/// A station is remembered by its seed, written `track:…`, `album:…` or
/// `artist:…`: Melete numbers tracks, albums and artists apart, so a bare id
/// can't say which it is. A bare id, as stations were written before, is read as
/// a track.
@MainActor
enum Station {
    /// How many songs a station starts with.
    static let length = 100

    /// How `item` is written as a station's seed.
    static func seed(for item: MusicItem) -> String {
        switch item.type {
        case .musicAlbum: "album:\(item.id)"
        case .musicArtist: "artist:\(item.id)"
        default: "track:\(item.id)"
        }
    }

    /// The station's songs, in the order they play.
    static func tracks(seed: String, client: MeleteClient) async throws -> [MusicItem] {
        guard let first = try await firstSong(seed: seed, client: client) else { return [] }
        let request = NextChooser.Request(seed: first.id, queue: [], recent: [], mode: .infinity, limit: length - 1)
        let chosen = try NextChooser.decode(try await client.next(body: NextChooser.encode(request)))
            .candidates.map(\.id).filter { $0 != first.id }
        let songs = [first] + (try await client.items(ids: chosen))
        return await TasteStore.shared.withoutNotInterested(songs)
    }

    /// The song a seed starts from.
    private static func firstSong(seed: String, client: MeleteClient) async throws -> MusicItem? {
        let parts = seed.split(separator: ":", maxSplits: 1).map(String.init)
        let (kind, id) = parts.count == 2 ? (parts[0], parts[1]) : ("track", seed)
        switch kind {
        case "album": return try await client.tracks(inAlbum: id).first
        case "artist": return try await client.songs(byArtist: id, limit: 1).first
        default: return try await client.items(ids: [id]).first
        }
    }
}
