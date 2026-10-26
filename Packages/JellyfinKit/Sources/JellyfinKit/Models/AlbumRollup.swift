import Foundation

/// Aggregates track-level listening data up to albums.
///
/// This exists because Jellyfin keeps no play statistics on albums at all.
/// `MusicAlbum` and `MusicArtist` both declare `SupportsPlayedStatus => false`;
/// only `Audio` items carry `PlayCount`, `Played` and `LastPlayedDate`. Sorting a
/// `MusicAlbum` query by `PlayCount`, or filtering it by `IsPlayed`, resolves
/// against the album's own (always-empty) user-data row and therefore returns
/// arbitrary results — which is exactly the bug this replaced.
///
/// So "most played albums" has to be computed here: ask for tracks, group them,
/// and rank the groups.
public enum AlbumRollup {
    /// One album, with its listening data summed from the tracks we saw.
    public struct Aggregate: Identifiable, Sendable {
        public let album: JellyfinItem
        /// Summed across the tracks in the response — a sample, not the whole album,
        /// unless every track happened to come back.
        public let playCount: Int
        public let lastPlayed: Date?
        /// How many of this album's tracks contributed. Useful for not promoting an
        /// album on the strength of one heavily-repeated song.
        public let trackCount: Int

        public var id: String { album.id }
    }

    /// Groups tracks into albums, newest-listened first or most-played first.
    ///
    /// Tracks with no `albumId` (loose files, which a personal library always has)
    /// are skipped rather than each becoming their own pseudo-album.
    ///
    /// The synthesised album item carries the track's `albumId`/`album` name and
    /// borrows its artwork tag, so it renders in an album grid without a second
    /// round trip per album.
    public static func aggregate(tracks: [JellyfinItem]) -> [Aggregate] {
        var order: [String] = []
        var byAlbum: [String: Tally] = [:]

        for track in tracks {
            guard let albumId = track.albumId, !albumId.isEmpty else { continue }

            let plays = track.userData?.playCount ?? 0
            let last = track.userData?.lastPlayedDate

            if var existing = byAlbum[albumId] {
                existing.plays += plays
                existing.count += 1
                if let last, existing.last.map({ last > $0 }) ?? true { existing.last = last }
                byAlbum[albumId] = existing
            } else {
                order.append(albumId)
                byAlbum[albumId] = Tally(
                    album: synthesiseAlbum(from: track, albumId: albumId), plays: plays, last: last, count: 1
                )
            }
        }

        return order.compactMap { id in
            guard let e = byAlbum[id] else { return nil }
            return Aggregate(album: e.album, playCount: e.plays, lastPlayed: e.last, trackCount: e.count)
        }
    }

    /// One album's running totals while the tracks are walked.
    private struct Tally {
        let album: JellyfinItem
        var plays: Int
        var last: Date?
        var count: Int
    }

    /// Ranks aggregates by total plays, then by recency to break ties.
    public static func rankedByPlayCount(_ aggregates: [Aggregate], limit: Int) -> [JellyfinItem] {
        aggregates
            .filter { $0.playCount > 0 }
            .sorted {
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
            }
            .prefix(limit)
            .map(\.album)
    }

    /// Ranks aggregates by how recently any of their tracks was played.
    public static func rankedByRecency(_ aggregates: [Aggregate], limit: Int) -> [JellyfinItem] {
        aggregates
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map(\.album)
    }

    /// Builds a `MusicAlbum`-shaped item out of one of its tracks.
    ///
    /// A track carries its album's id, name and artwork tag, which is everything an
    /// album cell renders — so we can show the grid immediately instead of issuing
    /// one request per album just to learn its title.
    private static func synthesiseAlbum(from track: JellyfinItem, albumId: String) -> JellyfinItem {
        JellyfinItem(
            id: albumId,
            name: track.album ?? track.name,
            type: .musicAlbum,
            albumArtist: track.albumArtist ?? track.artists.first,
            artists: track.artists,
            productionYear: track.productionYear,
            imageTags: track.albumPrimaryImageTag.map { ["Primary": $0] } ?? [:],
            userData: nil
        )
    }
}
