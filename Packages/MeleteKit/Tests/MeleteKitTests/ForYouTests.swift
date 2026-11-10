import Foundation
import Testing
@testable import MeleteKit

@Suite("For You")
struct ForYouTests {
    private static func song(_ id: String, _ title: String, poster: Any = NSNull()) -> [String: Any] {
        [
            "kind": "song", "mb_recording_id": id, "title": title, "artist": "The Quiet Engines",
            "mb_artist_ids": ["a-1"], "release": "Low Tide", "poster": poster,
        ]
    }

    private static func because(_ kind: String, _ title: Any, _ artist: String) -> [String: Any] {
        ["kind": kind, "title": title, "artist": artist]
    }

    private static func item(_ state: String, track: Any = NSNull(), song: Any = NSNull(), requestId: Any = NSNull()) -> [String: Any] {
        [
            "state": state, "track": track, "song": song, "request_id": requestId,
            "because": because("song", "Harbour Lights", "Paper Kites Club"),
        ]
    }

    private static func list(_ state: String, madeAt: Any = NSNull(), items: [[String: Any]] = []) -> Data {
        Fixture.json(["state": state, "made_at": madeAt, "items": items])
    }

    /// A client whose For You answers `body`, and that checks the limit asked for.
    private static func client(_ host: String, limit: String = "40", status: Int = 200, body: Data) -> MeleteClient {
        StubServer.client(host: host) { request, _ in
            guard request.httpMethod == "GET", request.url?.path() == "/api/v1/music/for-you",
                  request.query("limit") == limit
            else { return (404, Data()) }
            return (status, body)
        }
    }

    @Test("a ready list gives songs to play, asked for and to ask for, in its order")
    func ready() async throws {
        let body = Self.list("ready", madeAt: 1_790_000_000, items: [
            Self.item("playable", track: Fixture.track(11, "Slow Water", albumId: 4)),
            Self.item("requested", song: Self.song("rec-2", "Glass Pier"), requestId: 9),
            Self.item("requested", song: Self.song("rec-3", "Wanted Already")),
            Self.item("requestable", song: Self.song("rec-4", "Night Ferry", poster: "/api/v1/music/release-groups/rg-4/cover")),
        ])
        let forYou = try await Self.client("for-you-ready.test", body: body).forYou()
        #expect(forYou.state == .ready)
        #expect(forYou.madeAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(forYou.items.map(\.id) == ["track-11", "song-rec-2", "song-rec-3", "song-rec-4"])
        #expect(forYou.items[0].track?.name == "Slow Water")
        #expect(forYou.items[0].track?.coverAlbumId == "4")
        guard case .requested(let asked, let requestId) = forYou.items[1].offer else {
            Issue.record("not requested")
            return
        }
        #expect(asked.title == "Glass Pier" && requestId == 9)
        let wanted = try Self.decodedSong("rec-3", "Wanted Already")
        #expect(forYou.items[2].offer == ForYouItem.Offer.requested(wanted, requestId: nil))
        guard case .requestable(let song) = forYou.items[3].offer else {
            Issue.record("not requestable")
            return
        }
        #expect(song.kind == RequestKind.song && song.mbRecordingId == "rec-4" && song.artist == "The Quiet Engines")
        #expect(song.mbArtistIds == ["a-1"] && song.release == "Low Tide")
        #expect(song.poster == "/api/v1/music/release-groups/rg-4/cover")
        #expect(forYou.items[3].track == nil)
    }

    private static func decodedSong(_ id: String, _ title: String) throws -> ForYouSong {
        try JSONDecoder.melete.decode(ForYouSong.self, from: Fixture.json(song(id, title)))
    }

    @Test("off, no history and waiting have no songs", arguments: [
        ("off", ForYou.State.off), ("no_history", .noHistory), ("waiting", .waiting),
    ])
    func notReady(raw: String, state: ForYou.State) async throws {
        let host = "for-you-\(raw.replacingOccurrences(of: "_", with: "-")).test"
        let forYou = try await Self.client(host, body: Self.list(raw)).forYou()
        #expect(forYou.state == state)
        #expect(forYou.madeAt == nil && forYou.items.isEmpty)
    }

    @Test("a ready list can be empty")
    func readyEmpty() async throws {
        let forYou = try await Self.client("for-you-empty.test", body: Self.list("ready", madeAt: 1_790_000_000)).forYou()
        #expect(forYou.state == .ready && forYou.items.isEmpty)
    }

    @Test("a server before For You answers 404")
    func olderServer() async throws {
        let client = StubServer.client(host: "for-you-older.test") { _, _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        await #expect {
            _ = try await client.forYou()
        } throws: { error in
            if case MeleteError.notFound = error { return true }
            return false
        }
    }

    @Test("the limit asked for is sent")
    func limit() async throws {
        let forYou = try await Self.client("for-you-limit.test", limit: "12", body: Self.list("waiting")).forYou(limit: 12)
        #expect(forYou.state == .waiting)
    }

    @Test("optional fields may be absent, and what can't be used is left out")
    func tolerance() async throws {
        let body = Fixture.json([
            "state": "ready",
            "items": [
                // Only what's required to show and ask for it.
                ["state": "requestable", "song": ["mb_recording_id": "rec-1", "title": "Bare Song"],
                 "because": ["kind": "artist", "artist": "Paper Kites Club"]],
                ["state": "requested", "song": ["mb_recording_id": "rec-2", "title": "Asked Song"],
                 "because": ["kind": "song", "artist": "Paper Kites Club"]],
                // A song to play without its track, and a state this app doesn't know.
                ["state": "playable", "because": ["kind": "song", "title": "X", "artist": "Y"]],
                ["state": "borrowed", "song": Self.song("rec-3", "Later"), "because": ["kind": "mood", "artist": "Z"]],
                ["state": "playable", "track": Fixture.track(5, "Kept"), "because": ["kind": "mood", "artist": "Z"]],
            ],
        ])
        let forYou = try await Self.client("for-you-tolerant.test", body: body).forYou()
        #expect(forYou.madeAt == nil)
        #expect(forYou.items.map(\.id) == ["song-rec-1", "song-rec-2", "track-5"])
        guard case .requestable(let song) = forYou.items[0].offer else {
            Issue.record("not requestable")
            return
        }
        #expect(song.kind == RequestKind.song && song.artist.isEmpty && song.mbArtistIds.isEmpty)
        #expect(song.release == nil && song.poster == nil)
        guard case .requested(_, let requestId) = forYou.items[1].offer else {
            Issue.record("not requested")
            return
        }
        #expect(requestId == nil)
        #expect(forYou.items[2].because.kind == .artist)
    }

    @Test("a state this app doesn't know shows as off, without songs")
    func unknownState() async throws {
        let body = Self.list("thinking", items: [Self.item("playable", track: Fixture.track(1, "One"))])
        let forYou = try await Self.client("for-you-unknown.test", body: body).forYou()
        #expect(forYou.state == .off && forYou.items.isEmpty)
    }

    @Test("because names the song, else the artist")
    func because() throws {
        func line(_ kind: String, _ title: Any, _ artist: String) throws -> String {
            try JSONDecoder.melete.decode(ForYouBecause.self, from: Fixture.json(Self.because(kind, title, artist))).line
        }
        #expect(try line("song", "Harbour Lights", "Paper Kites Club") == "Because you listened to Harbour Lights")
        #expect(try line("artist", NSNull(), "Paper Kites Club") == "Because you listened to Paper Kites Club")
        #expect(try line("song", " ", "Paper Kites Club") == "Because you listened to Paper Kites Club")
    }

    @Test("asking for a suggested song sends its kind and recording id only")
    func ask() async throws {
        let client = StubServer.client(host: "for-you-ask.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard request.httpMethod == "POST", request.url?.path() == "/api/v1/requests",
                  sent?.count == 2, sent?["kind"] as? String == "song", sent?["mb_recording_id"] as? String == "rec-4"
            else { return (400, Data()) }
            return (201, Fixture.json([
                "id": 12, "kind": "song", "title": "Night Ferry", "year": NSNull(), "artist": "The Quiet Engines",
                "state": "requested", "reason": NSNull(), "created_at": 1_790_000_000, "decided_at": NSNull(),
                "decided_by": NSNull(), "progress": NSNull(),
            ]))
        }
        let request = try await client.askFor(try Self.decodedSong("rec-4", "Night Ferry"))
        #expect(request.id == 12 && request.state == .requested)
    }
}
