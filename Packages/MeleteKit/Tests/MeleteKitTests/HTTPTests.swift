import Foundation
import Testing
@testable import MeleteKit

// MARK: - Over HTTP

@Suite("Over HTTP")
struct HTTPTests {
    @Test("sign-in sends the device's name and keeps the session")
    func signIn() async throws {
        let client = StubServer.client(host: "signin.test") { request, body in
            let sent = try? JSONSerialization.jsonObject(with: body) as? [String: String]
            guard request.url?.path() == "/api/v1/auth/login",
                  sent == ["username": "alex", "password": "pw", "device_name": "Test"]
            else { return (400, Data()) }
            return (200, Fixture.session(3, "alex"))
        }
        let (credentials, user) = try await client.signedOut().signIn(username: "alex", password: "pw")
        #expect(credentials.userId == "3" && credentials.accessToken == "mlt_new")
        #expect(user.name == "alex")
    }

    @Test("something that isn't Melete is named as such")
    func notMelete() async throws {
        let client = StubServer.client(host: "router.test") { _, _ in (200, Data("<html>".utf8)) }
        await #expect(throws: MeleteError.notAMeleteServer(client.serverURL)) {
            try await client.signedOut().serverInfo()
        }
    }

    @Test("Quick Connect waits, then signs in once approved")
    func quickConnect() async throws {
        let polls = Counter()
        let client = StubServer.client(host: "qc.test") { request, _ in
            switch request.url?.path() {
            case "/api/v1/auth/quick-connect":
                return (200, Fixture.json(["code": "482913", "secret": "s3cret", "expires_in": 300]))
            case "/api/v1/auth/quick-connect/poll":
                return polls.next() == 0 ? (202, Data()) : (200, Fixture.session(9, "bea"))
            default:
                return (404, Data())
            }
        }.signedOut()
        let code = try await client.startQuickConnect()
        #expect(code.code == "482913" && code.expiresIn == 300)
        #expect(try await client.pollQuickConnect(secret: code.secret) == nil)
        let approved = try await client.pollQuickConnect(secret: code.secret)
        #expect(approved?.1.name == "bea")
    }

    @Test("tracks by id come back in the order asked, the missing ones absent")
    func itemsInOrder() async throws {
        let client = StubServer.client(host: "ids.test") { request, _ in
            let ids = (request.query("id") ?? "").split(separator: ",").compactMap { Int($0) }
            // The server's own order, and track 7 gone from the library.
            let found = ids.filter { $0 != 7 }.reversed().map { Fixture.track($0, "Track \($0)") }
            return (200, Fixture.page(Array(found)))
        }
        let items = try await client.items(ids: ["3", "7", "1", "3"])
        #expect(items.map(\.id) == ["3", "1", "3"])
    }

    @Test("an unlimited list is read page by page")
    func wholeList() async throws {
        let client = StubServer.client(host: "pages.test") { request, _ in
            let offset = Int(request.query("offset") ?? "0") ?? 0
            let ids = offset == 0 ? Array(1...500) : Array(501...520)
            return (200, Fixture.page(ids.map { Fixture.track($0, "T") }, total: 520))
        }
        let page = try await client.songs()
        #expect(page.items.count == 520)
        #expect(StubServer.requests(to: "pages.test").count == 2)
    }

    @Test("an album gives itself and its tracks in one request")
    func album() async throws {
        let client = StubServer.client(host: "album.test") { _, _ in
            var album = Fixture.album(2, "First Album")
            album["track_list"] = [Fixture.track(1, "Opening", albumId: 2), Fixture.track(2, "Closing", albumId: 2)]
            return (200, Fixture.json(album))
        }
        let (album, tracks) = try await client.album(id: "2")
        #expect(album.name == "First Album" && album.type == .musicAlbum)
        #expect(tracks.map(\.name) == ["Opening", "Closing"])
        #expect(!album.liked, "a server that doesn't say")
    }

    @Test("a stream link is joined beneath a proxy prefix, and refused elsewhere")
    func streamLink() async throws {
        let client = StubServer.client(host: "stream.test", path: "/melete") { request, body in
            let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            guard request.url?.path() == "/melete/api/v1/music/tracks/2/play",
                  sent?["format"] as? String == "aac", sent?["bitrate_kbps"] as? Int == 256
            else { return (400, Data()) }
            return (200, Fixture.json([
                "stream_url": "/api/v1/music/stream/abc", "expires_at": 1, "format": "aac",
                "content_type": "audio/mp4", "duration_seconds": 20.0, "gapless": NSNull(), "spatial": NSNull(),
            ]))
        }
        let lazy = try client.streamURL(for: "2", quality: .medium)
        let link = try await client.streamLink(forLazyURL: lazy)
        #expect(link.url.absoluteString == "http://stream.test/melete/api/v1/music/stream/abc")

        let elsewhere = StubServer.client(host: "steal.test") { _, _ in
            (200, Fixture.json(["stream_url": "https://elsewhere.example/x", "expires_at": 1, "content_type": "audio/flac"]))
        }
        await #expect(throws: (any Error).self) { try await elsewhere.streamLink(for: "2") }
    }

    @Test("a lossless file this device can't play is asked for again as FLAC")
    func unplayableFallsBackToFlac() async throws {
        let client = StubServer.client(host: "opus.test") { request, body in
            let sent = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let format = sent?["format"] as? String
            let type = format == "flac" ? "audio/flac" : "audio/ogg"
            return (200, Fixture.json([
                "stream_url": "/api/v1/music/stream/\(format ?? "none")", "expires_at": 1,
                "format": format ?? "original", "content_type": type,
            ]))
        }
        let link = try await client.streamLink(for: "4", canPlay: { $0 != "audio/ogg" })
        #expect(link.contentType == "audio/flac")
        #expect(link.url.path() == "/api/v1/music/stream/flac")
        #expect(StubServer.requests(to: "opus.test").count == 2)

        let playable = try await client.streamLink(for: "4", canPlay: { _ in true })
        #expect(playable.contentType == "audio/ogg", "a file it can play stays as it is")
        let aac = try await client.streamLink(for: "4", quality: .high, canPlay: { _ in false })
        #expect(aac.url.path() == "/api/v1/music/stream/aac", "only lossless falls back")
    }

    @Test("lyrics, or none")
    func lyrics() async throws {
        let client = StubServer.client(host: "lyrics.test") { request, _ in
            request.url?.path().contains("/2/") == true
                ? (200, Fixture.json(["track_id": 2, "source": "file", "synced": true,
                                      "lines": [["start_seconds": 1.0, "text": "First"]]]))
                : (404, Fixture.json(["error": "no lyrics are known for this track"]))
        }
        #expect(try await client.lyrics(forItem: "2")?.lines.first?.start == .seconds(1))
        #expect(try await client.lyrics(forItem: "3") == nil)
    }

    @Test("liking puts and unliking deletes")
    func likes() async throws {
        let client = StubServer.client(host: "like.test") { _, _ in (204, Data()) }
        try await client.setLiked(true, trackId: "4")
        try await client.setLiked(false, trackId: "4")
        let methods = StubServer.requests(to: "like.test").map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(methods == ["PUT /api/v1/music/tracks/4/like", "DELETE /api/v1/music/tracks/4/like"])
    }

    @Test("albums are liked, listed, and marked on their page")
    func albumLikes() async throws {
        let client = StubServer.client(host: "album-like.test") { request, _ in
            switch request.url?.path() {
            case "/api/v1/music/albums/2/like": return (204, Data())
            case "/api/v1/music/albums/2":
                var album = Fixture.album(2, "First Album")
                album["liked"] = true
                album["track_list"] = [[String: Any]]()
                return (200, Fixture.json(album))
            case "/api/v1/music/likes":
                return (200, Fixture.json(["tracks": [[String: Any]](), "albums": [
                    ["liked_at": 2, "content_key": "an artist|first album", "album": Fixture.album(2, "First Album")],
                    ["liked_at": 1, "content_key": "gone|album", "album": NSNull()],
                ]]))
            default: return (404, Data())
            }
        }
        try await client.setLiked(true, albumId: "2")
        try await client.setLiked(false, albumId: "2")
        let methods = StubServer.requests(to: "album-like.test").map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
        #expect(methods == ["PUT /api/v1/music/albums/2/like", "DELETE /api/v1/music/albums/2/like"])
        #expect(try await client.album(id: "2").album.liked)
        let liked = try await client.likedAlbums()
        #expect(liked.map(\.name) == ["First Album"] && liked.allSatisfy(\.liked))
        #expect(try await client.likedTracks().isEmpty)
    }

    @Test("a query over two genres asks for each, and keeps only its years")
    func queryAcrossGenres() async throws {
        let client = StubServer.client(host: "query.test") { request, _ in
            switch request.query("genre") {
            case "Folk": (200, Fixture.page([Fixture.track(1, "A", year: 1995), Fixture.track(2, "B", year: 2010)]))
            case "Jazz": (200, Fixture.page([Fixture.track(3, "C", year: 1999), Fixture.track(1, "A", year: 1995)]))
            default: (400, Data())
            }
        }
        let found = try await client.songs(matching: MusicQuery(
            genres: ["Folk", "Jazz"], years: Array(1990...1999)
        ))
        #expect(found.map(\.id) == ["1", "3"])
        #expect(StubServer.requests(to: "query.test").allSatisfy { $0.query("limit") == "500" })
    }
}

/// A count shared between a test and its stand-in server.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The count before this call.
    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
