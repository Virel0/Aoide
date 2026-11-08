import Foundation
import Testing
@testable import MeleteKit

@Suite("Collections saved on the web")
struct CollectionTests {
    private static var saved: [String: Any] {
        [
        "id": 3, "name": "Late Jazz", "genres": ["Jazz", "Soul"], "year_from": 1960, "year_to": 1969,
        "liked": true, "created_at": 1_790_000_000,
        ]
    }

    @Test("a collection's filter is the songs list's: genres by semicolons, years, liked")
    func filters() throws {
        let collection = try JSONDecoder.melete.decode(SongCollection.self, from: Fixture.json(Self.saved))
        #expect(collection.filters == [
            URLQueryItem(name: "genres", value: "Jazz;Soul"),
            URLQueryItem(name: "year_from", value: "1960"),
            URLQueryItem(name: "year_to", value: "1969"),
            URLQueryItem(name: "liked", value: "true"),
        ])
        #expect(collection.summary == "Jazz, Soul · 1960–1969 · Liked songs")
        let open = SongCollection(id: 1, name: "Old", yearTo: 1979)
        #expect(open.filters == [URLQueryItem(name: "year_to", value: "1979")])
        #expect(open.summary == "Up to 1979")
        #expect(SongCollection(id: 2, name: "One year", yearFrom: 1999, yearTo: 1999).summary == "1999")
    }

    @Test("collections are listed, their songs read by the filter, shuffled by the server, and deleted")
    func endpoints() async throws {
        let client = StubServer.client(host: "collections.test") { request, _ in
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/v1/music/collections"):
                return (200, Fixture.json(["items": [Self.saved]]))
            case ("GET", "/api/v1/music/tracks"):
                guard request.query("genres") == "Jazz;Soul", request.query("year_from") == "1960",
                      request.query("liked") == "true", request.query("limit") == "500"
                else { return (400, Data()) }
                let sort = request.query("sort")
                let tracks = sort == "random" ? [Fixture.track(2, "b"), Fixture.track(1, "a")]
                    : [Fixture.track(1, "a"), Fixture.track(2, "b")]
                return (200, Fixture.page(tracks, total: 2))
            case ("DELETE", "/api/v1/music/collections/3"):
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let found = try await client.collections()
        #expect(found.map(\.name) == ["Late Jazz"])
        #expect(try await client.songs(in: found[0], limit: 500).items.map(\.id) == ["1", "2"])
        #expect(try await client.songs(in: found[0], shuffled: true, limit: 500).items.map(\.id) == ["2", "1"])
        try await client.deleteCollection(3)
    }

    @Test("a server before collections has none")
    func olderServer() async throws {
        let client = StubServer.client(host: "old-collections.test") { _, _ in (404, Data()) }
        #expect(try await client.collections().isEmpty)
    }
}
