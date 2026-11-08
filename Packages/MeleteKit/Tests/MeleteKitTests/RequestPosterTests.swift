import Foundation
import Testing
@testable import MeleteKit

@Suite("Pictures in a search for music to ask for")
struct RequestPosterTests {
    private static func artist(poster: Any, credit: Any) -> [String: Any] {
        [
            "kind": "artist", "tmdb_id": NSNull(), "mb_artist_id": "a-1", "mb_release_group_id": NSNull(),
            "mb_recording_id": NSNull(), "title": "The Quiet Engines", "year": NSNull(), "artist": NSNull(),
            "detail": "Group, GB", "in_library": false, "wanted": false, "requested": NSNull(),
            "poster": poster, "closeness": 100, "overview": NSNull(), "poster_credit": credit,
        ]
    }

    private func candidate(_ raw: [String: Any]) throws -> RequestCandidate {
        try JSONDecoder.melete.decode(RequestCandidate.self, from: Fixture.json(raw))
    }

    @Test("an artist's portrait comes with its author and licence")
    func portrait() throws {
        let found = try candidate(Self.artist(poster: "/api/v1/music/artist-portraits/a-1", credit: [
            "author": "Jane Doe", "licence": "CC BY-SA 4.0",
            "licence_url": "https://creativecommons.org/licenses/by-sa/4.0/",
            "source_url": "https://commons.wikimedia.org/wiki/File:Quiet_Engines.jpg",
        ]))
        #expect(found.poster == "/api/v1/music/artist-portraits/a-1")
        #expect(found.posterCredit?.line == "Photo: Jane Doe, CC BY-SA 4.0")
        #expect(found.posterCredit?.link?.absoluteString == "https://commons.wikimedia.org/wiki/File:Quiet_Engines.jpg")
    }

    @Test("without the new fields (an older server), there's no picture")
    func olderServer() throws {
        var raw = Self.artist(poster: NSNull(), credit: NSNull())
        raw["poster_credit"] = nil
        let found = try candidate(raw)
        #expect(found.poster == nil && found.posterCredit == nil)
    }

    @Test("a credit names what it has, links only to the web, and is nothing when empty")
    func creditLine() throws {
        func credit(_ fields: [String: Any]) throws -> PosterCredit {
            try JSONDecoder.melete.decode(PosterCredit.self, from: Fixture.json(fields))
        }
        let licenceOnly = try credit(["licence": "CC0", "licence_url": "https://example.org/cc0"])
        #expect(licenceOnly.line == "Photo: CC0")
        #expect(licenceOnly.link?.absoluteString == "https://example.org/cc0")
        #expect(try credit(["author": " ", "source_url": "javascript:alert(1)"]).line == nil)
        #expect(try credit(["author": "A", "source_url": "javascript:alert(1)"]).link == nil)
    }

    @Test("a poster is fetched from this server at a size it makes, and only from here")
    func posterURL() {
        let client = StubServer.client(host: "posters.test") { _, _ in (404, Data()) }
        let url = client.posterURL("/api/v1/music/release-groups/rg-1/cover", maxWidth: 132)
        #expect(url?.absoluteString == "http://posters.test/api/v1/music/release-groups/rg-1/cover?size=160")
        #expect(client.posterURL("https://elsewhere.example/x.jpg", maxWidth: 160) == nil)
        #expect(client.posterURL("/api/v1/../../etc", maxWidth: 160) == nil)
    }
}
