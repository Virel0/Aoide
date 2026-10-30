import Foundation
import Testing
@testable import MeleteKit

// MARK: - Server address parsing

@Suite("Server URL normalisation")
struct ServerURLTests {
    @Test(
        "a bare LAN host gets http, which ATS permits",
        arguments: [
            ("192.168.1.10:8100", "http://192.168.1.10:8100"),
            ("10.0.0.5:8100", "http://10.0.0.5:8100"),
            ("172.16.3.1", "http://172.16.3.1"),
            ("melete.local:8100", "http://melete.local:8100"),
            ("localhost:8100", "http://localhost:8100"),
            ("melete", "http://melete"),
        ]
    )
    func bareLocalHost(_ input: String, _ expected: String) throws {
        let url = try MeleteClient.normalizeServerURL(input)
        #expect(url.absoluteString == expected)
    }

    /// Regression: this used to become `http://music.example.net`, which ATS blocks
    /// outright — the connection failed before it was ever attempted.
    @Test(
        "a bare public host gets https, because ATS forbids plain HTTP to one",
        arguments: [
            ("music.example.net", "https://music.example.net"),
            ("melete.example.com:8100", "https://melete.example.com:8100"),
            ("example.com/melete", "https://example.com/melete"),
            ("172.32.0.1", "https://172.32.0.1"),
        ]
    )
    func barePublicHost(_ input: String, _ expected: String) throws {
        let url = try MeleteClient.normalizeServerURL(input)
        #expect(url.absoluteString == expected)
    }

    @Test("an explicitly typed scheme always wins over the guess")
    func explicitSchemeWins() throws {
        let insecure = try MeleteClient.normalizeServerURL("http://music.example.net")
        #expect(insecure.absoluteString == "http://music.example.net")
    }

    @Test("a reverse-proxy subpath survives")
    func subpath() throws {
        let url = try MeleteClient.normalizeServerURL("https://example.com/melete/")
        #expect(url.absoluteString == "https://example.com/melete")
    }

    @Test("surrounding whitespace is forgiven")
    func whitespace() throws {
        let url = try MeleteClient.normalizeServerURL("  melete.local  ")
        #expect(url.absoluteString == "http://melete.local")
    }

    @Test("garbage is rejected", arguments: ["", "   ", "ftp://example.com", "http://", "://nope"])
    func rejectsGarbage(_ raw: String) {
        #expect(throws: (any Error).self) {
            try MeleteClient.normalizeServerURL(raw)
        }
    }
}

// MARK: - Requests

@Suite("Requests")
struct RequestTests {
    private func client(_ base: String, signedIn: Bool = true) throws -> MeleteClient {
        let url = try MeleteClient.normalizeServerURL(base)
        let client = MeleteClient(
            serverURL: url,
            device: DeviceProfile(client: "Aoide", device: "Test", deviceId: "dev-1", version: "1.0")
        )
        return signedIn
            ? client.authenticated(as: MeleteCredentials(serverURL: url, userId: "1", username: "alex", accessToken: "mlt_tok"))
            : client
    }

    @Test("paths append beneath a reverse-proxy prefix rather than replacing it")
    func proxyPrefix() throws {
        let url = try client("https://example.com/melete").url(path: "api/v1/health")
        #expect(url.absoluteString == "https://example.com/melete/api/v1/health")
    }

    @Test("a signed-in request carries the token as Bearer")
    func bearer() throws {
        let request = try client("https://music.example.net").request("GET", path: "api/v1/music/genres")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mlt_tok")
    }

    @Test("a signed-out request sends no Authorization at all")
    func signedOut() throws {
        let request = try client("https://music.example.net", signedIn: false).request("GET", path: "api/v1/health")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a path the server hands out keeps the proxy prefix")
    func servedPath() throws {
        let url = try client("https://example.com/melete").url(servedPath: "/api/v1/music/stream/abc")
        #expect(url?.absoluteString == "https://example.com/melete/api/v1/music/stream/abc")
    }

    @Test(
        "a path the server hands out can't leave the server",
        arguments: ["//elsewhere.example/x", "https://elsewhere.example/x", "api/relative", "/api/../admin", "/api/x?y=1", "/"]
    )
    func servedPathStaysHome(_ path: String) throws {
        #expect(try client("https://example.com").url(servedPath: path) == nil)
    }

    @Test("a lazy stream URL names its track and quality, and nothing secret")
    func lazyStreamURL() throws {
        let url = try client("https://music.example.net").streamURL(for: "42", quality: .medium)
        #expect(url.scheme == MeleteClient.lazyStreamScheme)
        #expect(!url.absoluteString.contains("mlt_tok"))
        let parsed = MeleteClient.lazyStream(url)
        #expect(parsed?.trackId == "42")
        #expect(parsed?.quality == .medium)
        #expect(MeleteClient.lazyStream(URL(string: "https://music.example.net/x")!) == nil)
    }

    @Test("asking for a stream while signed out throws rather than queueing a 401")
    func signedOutStreamThrows() throws {
        #expect(throws: MeleteError.notSignedIn) {
            try client("https://music.example.net", signedIn: false).streamURL(for: "1")
        }
    }

    @Test("a Melete error body gives its message")
    func errorDetail() {
        #expect(MeleteClient.detail(Data(#"{"error":"the scan is running"}"#.utf8)) == "the scan is running")
        #expect(MeleteClient.detail(Data("<html>Bad Gateway".utf8)) == "<html>Bad Gateway")
        #expect(MeleteClient.detail(Data("  ".utf8)) == nil)
    }
}

// MARK: - Decoding

@Suite("Decoding Melete's answers")
struct DecodingTests {
    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder.melete.decode(type, from: Fixture.json(value))
    }

    @Test("a track becomes an item with text ids and its album's cover")
    func track() throws {
        var raw = Fixture.track(4, "Café Song", genres: ["Jazz"], albumId: 2)
        raw["liked"] = true
        let item = try decode(WireTrack.self, raw).item
        #expect(item.id == "4")
        #expect(item.type == .audio)
        #expect(item.albumId == "2")
        #expect(item.artistItems == [NameIdPair(id: "7", name: "An Artist")])
        #expect(item.genres == ["Jazz"])
        #expect(item.duration == .seconds(200))
        #expect(item.liked)
        #expect(item.coverAlbumId == "2")
    }

    @Test("nulls in a track's lists decode as empty")
    func sparseTrack() throws {
        var raw = Fixture.track(1, "t")
        raw["genres"] = NSNull()
        raw["artists"] = NSNull()
        raw["liked"] = NSNull()
        raw["duration_seconds"] = -1
        let item = try decode(WireTrack.self, raw).item
        #expect(item.genres.isEmpty && item.artists.isEmpty && !item.liked)
        #expect(item.duration == nil)
    }

    @Test("an album without a cover draws nothing; a compilation names no artist")
    func albums() throws {
        var raw = Fixture.album(3, "Mixed", cover: false)
        raw["artist_id"] = NSNull()
        let item = try decode(WireAlbum.self, raw).item
        #expect(item.coverAlbumId == nil)
        #expect(item.albumArtistId == nil)
        #expect(try decode(WireAlbum.self, Fixture.album(5, "Own")).item.coverAlbumId == "5")
    }

    @Test("a genre is named by its name")
    func genre() throws {
        let item = try decode(WireGenre.self, ["name": "Rock", "tracks": 3, "albums": 1]).item
        #expect(item.id == "Rock" && item.type == .musicGenre)
    }
}

// MARK: - Offline lyrics storage

@Suite("Lyrics round trip")
struct LyricsCodableTests {
    private func decoded(_ json: String) throws -> LyricsTrack {
        LyricsTrack(try JSONDecoder.melete.decode(LyricsDocument.self, from: Data(json.utf8)))
    }

    /// Downloaded lyrics are written as the domain model and read back later. If the
    /// two directions ever disagree, an offline track shows lyrics that are subtly
    /// wrong — and only offline, where it's hardest to notice.
    @Test("a synced track survives being written to disk and read back")
    func syncedRoundTrip() throws {
        let track = try decoded("""
        {"lines":[
          {"text":"First line","start_seconds":1.0},
          {"text":"Second line","start_seconds":4.5}
        ]}
        """)

        let restored = try JSONDecoder().decode(LyricsTrack.self, from: JSONEncoder().encode(track))

        #expect(restored == track)
        #expect(restored.isSynced)
        #expect(restored.lines[1].start == .seconds(4.5))
        // The binary search must still find the right line after a round trip.
        #expect(restored.index(at: .seconds(4.6)) == 1)
    }

    @Test("an untimed track keeps its nil starts rather than collapsing them to zero")
    func untimedRoundTrip() throws {
        let track = try decoded(#"{"lines":[{"text":"No timing here","start_seconds":null}]}"#)

        let restored = try JSONDecoder().decode(LyricsTrack.self, from: JSONEncoder().encode(track))

        #expect(restored == track)
        #expect(!restored.isSynced)
        #expect(restored.lines[0].start == nil)
    }
}

// MARK: - Structured queries

@Suite("Music query")
struct MusicQueryTests {
    @Test("a decade becomes the list of years a query keeps")
    func decade() {
        #expect(MusicQuery.years(from: 1990, to: 1999) == Array(1990...1999))
    }

    @Test("a single year works from either end")
    func singleYear() {
        #expect(MusicQuery.years(from: 2004, to: 2004) == [2004])
    }

    @Test("an absurd span is dropped rather than truncated")
    func absurdSpan() {
        #expect(MusicQuery.years(from: 1900, to: 2025).isEmpty)
    }

    @Test("nonsense from the model is rejected", arguments: [
        (nil, nil), (2000, 1990), (0, 5), (99999, nil),
    ] as [(Int?, Int?)])
    func rejectsNonsense(_ from: Int?, _ to: Int?) {
        #expect(MusicQuery.years(from: from, to: to).isEmpty)
    }

    @Test("an unconstrained query is recognised as empty, not as everything")
    func emptyMeansEmpty() {
        #expect(MusicQuery().isEmpty)
        #expect(!MusicQuery(genres: ["Jazz"]).isEmpty)
        #expect(!MusicQuery(favoritesOnly: true).isEmpty)
        #expect(!MusicQuery(searchTerm: "abc").isEmpty)
    }

    @Test("the summary names what was understood")
    func summary() {
        let q = MusicQuery(genres: ["Rock"], years: Array(1990...1999), sort: .playCount)
        #expect(q.summary == "Rock · 1990–1999 · most played")
    }
}
