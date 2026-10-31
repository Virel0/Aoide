import Foundation
import Testing
@testable import MeleteKit

@Suite("Asking for music")
struct MusicRequestTests {
    private static func album(inLibrary: Bool = false, requested: Int? = nil) -> [String: Any] {
        [
            "kind": "album", "tmdb_id": NSNull(), "mb_artist_id": "a-1", "mb_release_group_id": "rg-1",
            "mb_recording_id": NSNull(), "title": "Low Tide", "year": 2019, "artist": "The Quiet Engines",
            "detail": "Album", "in_library": inLibrary, "wanted": false,
            "requested": requested as Any? ?? NSNull(), "poster": NSNull(),
        ]
    }

    private static func request(_ state: String, progress: Any = NSNull()) -> [String: Any] {
        [
            "id": 9, "user_id": 1, "username": "alice", "kind": "album", "service": "music",
            "tmdb_id": NSNull(), "season": NSNull(), "mb_artist_id": "a-1", "mb_release_group_id": "rg-1",
            "mb_recording_id": NSNull(), "title": "Low Tide", "year": 2019, "artist": "The Quiet Engines",
            "poster": NSNull(), "state": state, "reason": state == "declined" ? "not on any tracker" : NSNull(),
            "created_at": 1_790_000_000, "decided_at": NSNull(), "decided_by": NSNull(), "wanted_id": NSNull(),
            "progress": progress, "seasons": NSNull(), "search_started": false,
        ]
    }

    @Test("search, ask with only its kind's id, list music requests, withdraw")
    func requests() async throws {
        let client = StubServer.client(host: "requests.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/v1/requests/search"):
                guard request.query("kind") == "album", request.query("q") == "low tide" else { return (400, Data()) }
                return (200, Fixture.json([Self.album(), Self.album(inLibrary: true)]))
            case ("POST", "/api/v1/requests"):
                guard sent?.count == 2, sent?["kind"] as? String == "album",
                      sent?["mb_release_group_id"] as? String == "rg-1"
                else { return (400, Data()) }
                return (201, Fixture.json(Self.request("requested")))
            case ("GET", "/api/v1/requests"):
                guard request.query("service") == "music" else { return (400, Data()) }
                return (200, Fixture.json(["total": 1, "items": [Self.request("approved", progress: [
                    "kind": "album", "wanted_id": 3, "title": "Low Tide by The Quiet Engines",
                    "step": "downloading", "percent": 42.4, "message": "Downloading", "download_id": 7,
                    "source": "torrent", "updated_at": 1_790_000_100, "copied": NSNull(),
                ])]]))
            case ("DELETE", "/api/v1/requests/9"):
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let found = try await client.requestSearch(.album, words: " low tide ")
        #expect(found.map(\.isAskable) == [true, false])
        // Its type, Album, says its kind again and is left out.
        #expect(found[0].about == "Album · The Quiet Engines · 2019")
        let asked = try await client.askFor(found[0])
        #expect(asked.id == 9 && asked.state == .requested)
        let mine = try await client.musicRequests()
        #expect(mine.first?.standing == "Downloading, 42%")
        try await client.withdrawRequest(id: 9)
    }

    @Test("a request says where it stands")
    func standing() throws {
        func decoded(_ state: String, step: String? = nil) throws -> MusicRequest {
            let progress: Any = step.map { ["step": $0, "percent": NSNull(), "message": "No release fits"] } ?? NSNull()
            return try JSONDecoder.melete.decode(MusicRequest.self, from: Fixture.json(Self.request(state, progress: progress)))
        }
        #expect(try decoded("requested").standing == "Waiting for approval")
        #expect(try decoded("declined").standing == "Declined: not on any tracker")
        #expect(try decoded("approved", step: "in_library").standing == "In your library")
        #expect(try decoded("approved", step: "failed").standing == "Couldn't be fetched: No release fits")
    }
}
