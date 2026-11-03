import Foundation
import Testing
@testable import MeleteKit

@Suite("Imports that make a playlist")
struct PlaylistImportMakingTests {
    private static func summary(playlistId: Any, inLibrary: Int) -> [String: Any] {
        [
            "id": 7, "user_id": 1, "username": "alice", "name": "Road trip", "state": "running", "message": NSNull(),
            "created_at": 1_790_000_000, "finished_at": NSNull(), "tracks": 20, "asked": 4, "already": 1,
            "unmatched": 2, "waiting": 3, "in_library": inLibrary, "playlist_id": playlistId,
        ]
    }

    @Test("make_playlist is sent, and the playlist and the songs in the library come back")
    func makesPlaylist() async throws {
        let client = StubServer.client(host: "make.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            guard request.httpMethod == "POST", request.url?.path() == "/api/v1/requests/imports",
                  sent?["make_playlist"] as? Bool == true, sent?["name"] as? String == "Road trip"
            else { return (400, Data()) }
            return (202, Fixture.json(Self.summary(playlistId: "PL-1", inLibrary: 5)))
        }
        let started = try await client.importPlaylist(name: "Road trip", csv: "Track Name\nCreep\n", makePlaylist: true)
        #expect(started.playlistId == "PL-1")
        #expect(started.inLibrary == 5)
        #expect(started.handled == 12)
        #expect(started.tally
            == "Asking: 4 of 20 songs asked for, 1 asked already, 2 not found. 5 in your library already. 3 wait for approval.")
    }

    @Test("an older server's refusal of make_playlist reaches the caller as its status")
    func olderServerRefuses() async throws {
        let client = StubServer.client(host: "older.test") { _, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return sent?["make_playlist"] == nil ? (202, Data()) : (422, Data())
        }
        await #expect {
            _ = try await client.importPlaylist(name: "Road trip", csv: "Track Name\nCreep\n", makePlaylist: true)
        } throws: { error in
            if case MeleteError.http(status: 422, _, _) = error { true } else { false }
        }
    }

    @Test("an import that makes no playlist reads as before")
    func noPlaylist() throws {
        var fields = Self.summary(playlistId: NSNull(), inLibrary: 0)
        fields["in_library"] = nil
        fields["playlist_id"] = nil
        let summary = try JSONDecoder.melete.decode(PlaylistImportSummary.self, from: Fixture.json(fields))
        #expect(summary.playlistId == nil)
        #expect(summary.inLibrary == nil)
    }

    @Test("a song the library had is said to be there")
    func inLibraryStanding() throws {
        let track = try JSONDecoder.melete.decode(PlaylistImportTrack.self, from: Fixture.json([
            "position": 1, "title": "Creep", "artist": "Radiohead", "album": NSNull(), "isrc": NSNull(),
            "state": "in_library", "why": NSNull(), "request_id": NSNull(),
        ]))
        #expect(track.standing == "In your library")
    }
}
