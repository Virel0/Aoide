import Foundation
import Testing
@testable import MeleteKit

@Suite("Melete's music AI")
struct AITests {
    @Test("a phrase is posted as the query, and the filters come back as a query")
    func search() async throws {
        let client = StubServer.client(host: "ai-search.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            guard request.httpMethod == "POST", request.url?.path() == "/api/v1/ai/music/search",
                  sent == ["query": "upbeat rock from the nineties"]
            else { return (400, Data()) }
            return (200, Fixture.json([
                "search_term": NSNull(), "genres": ["Rock", "Art Rock"], "from_year": 1990,
                "to_year": 1999, "liked_only": true, "ordering": "most_played",
            ]))
        }
        let filters = try await client.musicFilters(describing: "upbeat rock from the nineties")
        #expect(filters.genres == ["Rock", "Art Rock"])
        #expect(filters.ordering == .mostPlayed)
        let query = filters.query
        #expect(query.searchTerm == nil)
        #expect(query.years == Array(1990...1999))
        #expect(query.favoritesOnly)
        #expect(query.sort == .playCount && query.direction == .descending)
    }

    @Test("a blank search term is no search term, and by name is A to Z")
    func blankTerm() throws {
        let filters = try JSONDecoder.melete.decode(MusicFilters.self, from: Fixture.json([
            "search_term": "  ", "genres": [], "from_year": NSNull(), "to_year": NSNull(),
            "liked_only": false, "ordering": "by_name",
        ]))
        #expect(filters.query.searchTerm == nil)
        #expect(filters.query.sort == .name && filters.query.direction == .ascending)
        #expect(filters.query.isEmpty)
    }

    @Test("a mood is posted as the description, and its rules keep their values' types")
    func mix() async throws {
        let client = StubServer.client(host: "ai-mix.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            guard request.httpMethod == "POST", request.url?.path() == "/api/v1/ai/music/mix",
                  sent == ["description": "Helldivers 2 session music"]
            else { return (400, Data()) }
            return (200, Fixture.json([
                "names": ["Helldivers 2"],
                "rules": ["match": "all", "limit": 40, "rules": [
                    ["field": "genre", "op": "is", "value": "Rock"],
                    ["field": "year", "op": "greaterThan", "value": 1989],
                    ["field": "liked", "op": "is", "value": true],
                    ["field": "last_played", "op": "notInTheLast", "value": "-6m"],
                ]],
                "rejected": ["contains does not apply to year"],
            ]))
        }
        let mix = try await client.musicMix(describing: "Helldivers 2 session music")
        #expect(mix.names == ["Helldivers 2"])
        #expect(mix.rejected == ["contains does not apply to year"])
        let rules = try #require(mix.rules)
        #expect(rules.match == "all" && rules.limit == 40)
        #expect(rules.rules.map(\.value) == [.text("Rock"), .number(1989), .flag(true), .text("-6m")])
        #expect(rules.rules.map(\.field) == ["genre", "year", "liked", "last_played"])
        #expect(rules.rules[3].op == "notInTheLast")
    }

    @Test("a mix with no usable rules has none, and no cap is nil")
    func noRules() throws {
        let none = try JSONDecoder.melete.decode(MusicMix.self, from: Fixture.json([
            "names": ["Muse"], "rules": NSNull(), "rejected": ["No usable rules."],
        ]))
        #expect(none.rules == nil && none.names == ["Muse"])
        let uncapped = try JSONDecoder.melete.decode(MusicMix.self, from: Fixture.json([
            "names": [], "rules": ["match": "any", "limit": NSNull(), "rules": []], "rejected": [],
        ]))
        #expect(uncapped.rules?.limit == nil)
    }

    @Test("AI is on when the server says so, and off without the route")
    func enabled() async throws {
        let on = StubServer.client(host: "ai-on.test") { request, _ in
            request.url?.path() == "/api/v1/ai" ? (200, Fixture.json(["enabled": true])) : (404, Data())
        }
        #expect(try await on.aiEnabled())
        let off = StubServer.client(host: "ai-off.test") { _, _ in (200, Fixture.json(["enabled": false])) }
        #expect(try await !off.aiEnabled())
        for status in [403, 404] {
            let missing = StubServer.client(host: "ai-missing-\(status).test") { _, _ in (status, Data()) }
            await #expect { try await missing.aiEnabled() } throws: { ($0 as? MeleteError)?.meansAIOff == true }
        }
        let broken = StubServer.client(host: "ai-broken.test") { _, _ in (500, Data()) }
        await #expect { try await broken.aiEnabled() } throws: { ($0 as? MeleteError)?.meansAIOff == false }
    }

    @Test("a Melete with AI on but older than the music AI answers 404, which means off")
    func olderMelete() async throws {
        let client = StubServer.client(host: "ai-older.test") { request, _ in
            request.url?.path() == "/api/v1/ai"
                ? (200, Fixture.json(["enabled": true]))
                : (404, Fixture.json(["error": "not found"]))
        }
        #expect(try await client.aiEnabled())
        await #expect { _ = try await client.musicFilters(describing: "upbeat rock from the nineties") } throws: {
            $0 as? MeleteError == .notFound(path: "api/v1/ai/music/search") && ($0 as? MeleteError)?.meansAIOff == true
        }
        await #expect { _ = try await client.musicMix(describing: "something calm") } throws: {
            $0 as? MeleteError == .notFound(path: "api/v1/ai/music/mix") && ($0 as? MeleteError)?.meansAIOff == true
        }
    }

    @Test("503 means AI is off; a busy or failed model doesn't, and keeps Melete's words")
    func failures() async throws {
        func failure(_ status: Int, _ error: String) async -> MeleteError? {
            let client = StubServer.client(host: "ai-\(status).test") { _, _ in (status, Fixture.json(["error": error])) }
            do {
                _ = try await client.musicMix(describing: "something calm")
                return nil
            } catch {
                return error as? MeleteError
            }
        }
        #expect(await failure(503, "AI features aren't set up")?.meansAIOff == true)
        #expect(await failure(404, "not found")?.meansAIOff == true)
        let limited = await failure(429, "that's 30 searches this hour; try again later")
        #expect(limited?.meansAIOff == false)
        #expect(limited == .http(
            status: 429, path: "api/v1/ai/music/mix", detail: "that's 30 searches this hour; try again later"
        ))
        #expect(await failure(502, "the OpenRouter account is out of credit")?.meansAIOff == false)
    }
}
