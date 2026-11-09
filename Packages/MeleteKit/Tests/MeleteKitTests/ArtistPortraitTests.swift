import Foundation
import Testing
@testable import MeleteKit

@Suite("A library artist's portrait")
struct ArtistPortraitTests {
    private static func artist(_ id: Int, portrait: Any, credit: Any) -> [String: Any] {
        [
            "id": id, "name": "The Quiet Engines", "mb_artist_id": NSNull(), "albums": 2, "appears_on": 0,
            "portrait": portrait, "portrait_credit": credit,
        ]
    }

    private static var credit: [String: Any] { [
        "author": "Jane Doe", "licence": "CC BY-SA 4.0",
        "licence_url": "https://creativecommons.org/licenses/by-sa/4.0/",
        "source_url": "https://commons.wikimedia.org/wiki/File:Quiet_Engines.jpg",
    ] }

    private func item(_ raw: [String: Any]) throws -> MusicItem {
        try JSONDecoder.melete.decode(WireArtist.self, from: Fixture.json(raw)).item
    }

    @Test("an artist's portrait and its credit are read; an older server's artist has neither")
    func decoded() throws {
        let found = try item(Self.artist(7, portrait: "/api/v1/music/artists/7/portrait", credit: Self.credit))
        #expect(found.portrait == "/api/v1/music/artists/7/portrait")
        #expect(found.portraitCredit?.line == "Photo: Jane Doe, CC BY-SA 4.0")

        let own = try item(Self.artist(8, portrait: "/api/v1/music/artists/8/portrait", credit: NSNull()))
        #expect(own.portrait != nil && own.portraitCredit == nil, "a picture of their own has no credit")

        var old = Self.artist(9, portrait: NSNull(), credit: NSNull())
        old["portrait"] = nil
        old["portrait_credit"] = nil
        let older = try item(old)
        #expect(older.portrait == nil && older.portraitCredit == nil)
    }

    @Test("an artist's picture is their portrait, at a size the server makes; none without one")
    func artworkURL() throws {
        let client = StubServer.client(host: "portraits.test") { _, _ in (404, Data()) }
        let found = try item(Self.artist(7, portrait: "/api/v1/music/artists/7/portrait", credit: NSNull()))
        #expect(
            client.artworkURL(for: found, maxWidth: 132)?.absoluteString
                == "http://portraits.test/api/v1/music/artists/7/portrait?size=160"
        )
        let none = try item(Self.artist(8, portrait: NSNull(), credit: NSNull()))
        #expect(client.artworkURL(for: none, maxWidth: 132) == nil)
        let elsewhere = try item(Self.artist(9, portrait: "https://elsewhere.example/x.jpg", credit: NSNull()))
        #expect(client.artworkURL(for: elsewhere, maxWidth: 132) == nil, "only a path on this server")
    }

    @Test("an artist's page gives the artist, portrait included, with their albums")
    func page() async throws {
        let client = StubServer.client(host: "artist-page.test") { request, _ in
            guard request.url?.path() == "/api/v1/music/artists/7" else { return (404, Data()) }
            var detail = Self.artist(7, portrait: "/api/v1/music/artists/7/portrait", credit: Self.credit)
            detail["album_list"] = [Fixture.album(1, "First")]
            detail["appears_on_list"] = [Fixture.album(2, "Guesting")]
            return (200, Fixture.json(detail))
        }
        let page = try await client.artistPage(id: "7")
        #expect(page.artist.name == "The Quiet Engines")
        #expect(page.artist.portrait == "/api/v1/music/artists/7/portrait")
        #expect(page.artist.portraitCredit?.link?.host() == "commons.wikimedia.org")
        #expect(page.albums.map(\.name) == ["First", "Guesting"])
        #expect(try await client.albums(byArtist: "7").count == 2)
    }

    @Test("the downloads' list keeps an artist's portrait, and reads one saved before it")
    func keptOnDisk() throws {
        let found = try item(Self.artist(7, portrait: "/api/v1/music/artists/7/portrait", credit: Self.credit))
        let saved = try JSONEncoder().encode(found)
        #expect(try JSONDecoder().decode(MusicItem.self, from: saved) == found)

        var old = try JSONSerialization.jsonObject(with: saved) as? [String: Any] ?? [:]
        old["portrait"] = nil
        old["portraitCredit"] = nil
        let before = try JSONDecoder().decode(MusicItem.self, from: Fixture.json(old))
        #expect(before.portrait == nil && before.name == found.name)
    }
}
