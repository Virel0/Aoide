import Foundation
import Testing
@testable import JellyfinKit

private func track(
    _ id: String,
    album: String?,
    albumName: String = "An Album",
    plays: Int = 0,
    lastPlayed: Date? = nil,
    artTag: String? = nil
) -> JellyfinItem {
    JellyfinItem(
        id: id,
        name: "Track \(id)",
        type: .audio,
        albumId: album,
        album: albumName,
        albumArtist: "An Artist",
        artists: ["An Artist"],
        albumPrimaryImageTag: artTag,
        userData: UserItemData(played: plays > 0, playCount: plays, lastPlayedDate: lastPlayed)
    )
}

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Album rollup")
struct AlbumRollupTests {
    @Test("sums play counts across an album's tracks")
    func sumsPlays() {
        let aggregates = AlbumRollup.aggregate(tracks: [
            track("1", album: "A", plays: 3),
            track("2", album: "A", plays: 4),
            track("3", album: "B", plays: 5),
        ])
        let a = try! #require(aggregates.first { $0.album.id == "A" })
        #expect(a.playCount == 7)
        #expect(a.trackCount == 2)
    }

    @Test("keeps the most recent play across an album's tracks")
    func keepsLatestPlay() {
        let aggregates = AlbumRollup.aggregate(tracks: [
            track("1", album: "A", plays: 1, lastPlayed: t0),
            track("2", album: "A", plays: 1, lastPlayed: t0.addingTimeInterval(3600)),
            track("3", album: "A", plays: 1, lastPlayed: t0.addingTimeInterval(-3600)),
        ])
        #expect(aggregates.first?.lastPlayed == t0.addingTimeInterval(3600))
    }

    /// A personal library always has loose files. Each one becoming its own
    /// single-track "album" would swamp every shelf.
    @Test("skips tracks with no album rather than inventing one each")
    func skipsOrphanTracks() {
        let aggregates = AlbumRollup.aggregate(tracks: [
            track("1", album: nil, plays: 99),
            track("2", album: "", plays: 99),
            track("3", album: "A", plays: 1),
        ])
        #expect(aggregates.count == 1)
        #expect(aggregates.first?.album.id == "A")
    }

    @Test("borrows the track's artwork tag so the album grid renders without extra requests")
    func borrowsArtwork() {
        let aggregates = AlbumRollup.aggregate(tracks: [
            track("1", album: "A", albumName: "Blue Lines", artTag: "tag99")
        ])
        let album = try! #require(aggregates.first?.album)
        #expect(album.name == "Blue Lines")
        #expect(album.type == .musicAlbum)
        #expect(album.imageTags["Primary"] == "tag99")
        #expect(album.artworkSource?.tag == "tag99")
    }

    @Test("ranks by total plays, not by any single track's count")
    func ranksByTotal() {
        // B has the single most-played track; A has more plays overall.
        let ranked = AlbumRollup.rankedByPlayCount(
            AlbumRollup.aggregate(tracks: [
                track("1", album: "A", plays: 6),
                track("2", album: "A", plays: 6),
                track("3", album: "B", plays: 10),
            ]),
            limit: 10
        )
        #expect(ranked.map(\.id) == ["A", "B"])
    }

    @Test("breaks play-count ties with recency")
    func tieBreak() {
        let ranked = AlbumRollup.rankedByPlayCount(
            AlbumRollup.aggregate(tracks: [
                track("1", album: "A", plays: 5, lastPlayed: t0),
                track("2", album: "B", plays: 5, lastPlayed: t0.addingTimeInterval(60)),
            ]),
            limit: 10
        )
        #expect(ranked.map(\.id) == ["B", "A"])
    }

    @Test("never-played albums stay out of Most Played")
    func excludesUnplayed() {
        let ranked = AlbumRollup.rankedByPlayCount(
            AlbumRollup.aggregate(tracks: [
                track("1", album: "A", plays: 0),
                track("2", album: "B", plays: 2),
            ]),
            limit: 10
        )
        #expect(ranked.map(\.id) == ["B"])
    }

    @Test("recency ranking ignores albums that were never played")
    func recencyExcludesUnplayed() {
        let ranked = AlbumRollup.rankedByRecency(
            AlbumRollup.aggregate(tracks: [
                track("1", album: "A", plays: 0, lastPlayed: nil),
                track("2", album: "B", plays: 1, lastPlayed: t0),
            ]),
            limit: 10
        )
        #expect(ranked.map(\.id) == ["B"])
    }

    @Test("honours the limit")
    func respectsLimit() {
        let tracks = (1...10).map { track("\($0)", album: "album\($0)", plays: $0) }
        let ranked = AlbumRollup.rankedByPlayCount(AlbumRollup.aggregate(tracks: tracks), limit: 3)
        #expect(ranked.count == 3)
        #expect(ranked.first?.id == "album10")
    }

    @Test("an empty response yields no albums rather than throwing")
    func empty() {
        #expect(AlbumRollup.aggregate(tracks: []).isEmpty)
        #expect(AlbumRollup.rankedByPlayCount([], limit: 5).isEmpty)
    }
}

@Suite("Jellyfin date parsing")
struct JellyfinDateTests {
    @Test(
        "parses the ISO 8601 shapes Jellyfin actually emits",
        arguments: [
            "2026-08-05T14:35:00Z",
            "2026-08-05T14:35:00.123Z",
            "2026-08-05T14:35:00.1234567Z",   // .NET's seven fractional digits
            "2026-08-05T14:35:00+01:00",
            "2026-08-05T14:35:00.500+01:00",
        ]
    )
    func parsesShapes(_ raw: String) {
        #expect(JellyfinDate.parse(raw) != nil)
    }

    @Test("rejects nonsense instead of returning a wrong date")
    func rejectsGarbage() {
        #expect(JellyfinDate.parse("not a date") == nil)
        #expect(JellyfinDate.parse("") == nil)
    }

    @Test("decodes lastPlayedDate through the real decoder")
    func decodesUserData() throws {
        let json = Data(#"{"Id":"x","UserData":{"PlayCount":4,"LastPlayedDate":"2026-08-05T14:35:00.1234567Z"}}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        #expect(item.userData?.playCount == 4)
        #expect(item.userData?.lastPlayedDate != nil)
    }
}
