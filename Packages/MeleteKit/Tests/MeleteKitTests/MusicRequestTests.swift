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
        #expect(mine.first?.standing == "Downloading by torrent, 42%")
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

    @Test("the feed hands over each requests event, music only, until the stream ends")
    @MainActor
    func feed() async throws {
        var copying = Self.request("approved", progress: [
            "kind": "album", "wanted_id": 3, "title": "Low Tide", "step": "transferring", "percent": NSNull(),
            "message": "Copying to the server", "download_id": 7, "source": "soulseek", "updated_at": 1_790_000_200,
            "copied": ["bytes": 50, "total": 200, "bytes_per_second": 10, "seconds_left": 15],
        ])
        copying["decided_at"] = 1_790_000_050
        copying["decided_by"] = "admin"
        var movie = Self.request("requested")
        movie["kind"] = "movie"
        let list = String(decoding: Fixture.json([copying, movie]), as: UTF8.self)
        let stream = ": keep-alive\n\nevent: sync\ndata: {}\n\nevent: requests\r\ndata: \(list)\r\n\r\n"
        let client = StubServer.client(host: "feed.test") { request, _ in
            guard request.url?.path() == "/api/v1/requests/events",
                  request.value(forHTTPHeaderField: "Accept") == "text/event-stream"
            else { return (404, Data()) }
            return (200, Data(stream.utf8))
        }
        var seen: [[MusicRequest]] = []
        try await client.followRequests { seen.append($0) }
        #expect(seen.count == 1)
        #expect(seen.first?.count == 1, "the movie is left out")
        let request = try #require(seen.first?.first)
        #expect(request.decidedBy == "admin")
        #expect(request.progress?.copied?.secondsLeft == 15)
        #expect(request.standing.hasPrefix("Copying to your server: "))
        #expect(request.standing.hasSuffix(", under a minute left"))

        let refused = StubServer.client(host: "feed-refused.test") { _, _ in (401, Data(#"{"error":"sign in"}"#.utf8)) }
        await #expect(throws: MeleteError.unauthorized) { try await refused.followRequests { _ in } }
    }

    @Test("the detail says who decided, when, and Melete's latest word")
    func detail() throws {
        let now = Date(timeIntervalSince1970: 1_790_010_000)
        let english = Locale(identifier: "en_US")
        var waiting = Self.request("requested")
        waiting["created_at"] = 1_790_010_000 - 7_200
        let asked = try JSONDecoder.melete.decode(MusicRequest.self, from: Fixture.json(waiting))
        #expect(asked.detail(now: now, locale: english) == "Asked 2 hours ago")
        var searching = Self.request("approved", progress: [
            "step": "searching", "percent": NSNull(), "message": "looking out for a release",
            "source": NSNull(), "updated_at": 1_790_010_000 - 120, "copied": NSNull(),
        ])
        searching["decided_at"] = 1_790_010_000 - 3_600
        searching["decided_by"] = "admin"
        let approved = try JSONDecoder.melete.decode(MusicRequest.self, from: Fixture.json(searching))
        #expect(approved.detail(now: now, locale: english)
            == "looking out for a release · Approved by admin 1 hour ago · Updated 2 minutes ago")
    }

    private static func importSummary() -> [String: Any] {
        [
            "id": 4, "user_id": 1, "username": "alice", "name": "Road trip", "state": "done", "message": NSNull(),
            "created_at": 1_790_000_000, "finished_at": 1_790_000_060, "tracks": 20, "asked": 12, "already": 3,
            "unmatched": 5, "waiting": 4,
        ]
    }

    @Test("a playlist import is started, listed, read song by song and removed")
    func imports() async throws {
        let client = StubServer.client(host: "imports.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/api/v1/requests/imports"):
                guard sent == ["name": "Road trip", "csv": "Track Name\nCreep\n"] else { return (400, Data()) }
                return (202, Fixture.json(Self.importSummary().merging(["state": "queued"]) { $1 }))
            case ("GET", "/api/v1/requests/imports"):
                return (200, Fixture.json([Self.importSummary()]))
            case ("GET", "/api/v1/requests/imports/4"):
                return (200, Fixture.json(Self.importSummary().merging(["items": [
                    ["position": 1, "title": "Creep", "artist": "Radiohead", "album": NSNull(), "isrc": NSNull(),
                     "state": "asked", "why": NSNull(), "request_id": 9],
                    ["position": 2, "title": "Nowhere", "artist": NSNull(), "album": NSNull(), "isrc": NSNull(),
                     "state": "unmatched", "why": "no recording fits", "request_id": NSNull()],
                ]]) { $1 }))
            case ("DELETE", "/api/v1/requests/imports/4"):
                return (200, Fixture.json(["taken_back": 4]))
            default:
                return (404, Data())
            }
        }
        let started = try await client.importPlaylist(name: "Road trip", csv: "Track Name\nCreep\n")
        #expect(started.isRunning)
        let listed = try await client.playlistImports()
        #expect(listed.first?.tally
            == "Done: 12 of 20 songs asked for, 3 asked already, 5 not found. 4 wait for approval.")
        let read = try await client.playlistImport(id: 4)
        #expect(read.summary.name == "Road trip")
        #expect(read.items.map(\.standing) == ["Asked for", "Not found: no recording fits"])
        try await client.removePlaylistImport(id: 4)
    }

    @Test("a playlist becomes Exportify's CSV, quotes doubled")
    func csv() {
        let csv = PlaylistCSV.make([
            ImportedTrack(title: "Say \"Hi\"", artists: ["Mara Vey", "Odd Hours"], album: "Low Tide", durationMs: 201_000),
            ImportedTrack(title: "Plain", artists: ["Someone"], isrc: "USX9P0000001"),
        ])
        #expect(csv == """
            Track Name,Artist Name(s),Album Name,Track Duration (ms),ISRC
            "Say ""Hi\"\"","Mara Vey, Odd Hours","Low Tide",201000,""
            "Plain","Someone","",,"USX9P0000001"

            """)
    }

    @Test("the feed's newest requests replace theirs and older ones stay")
    func merging() throws {
        func request(_ id: Int, _ state: String) throws -> MusicRequest {
            var fields = Self.request(state)
            fields["id"] = id
            return try JSONDecoder.melete.decode(MusicRequest.self, from: Fixture.json(fields))
        }
        let listed = try [request(3, "requested"), request(2, "requested"), request(1, "requested")]
        let live = try [request(4, "requested"), request(3, "approved")]
        let merged = MusicRequest.merging(live, over: listed)
        #expect(merged.map(\.id) == [4, 3, 2, 1])
        #expect(merged[1].state == .approved)
        #expect(MusicRequest.merging([], over: listed) == listed)
    }
}
