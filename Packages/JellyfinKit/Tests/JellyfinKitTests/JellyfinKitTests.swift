import Foundation
import Testing
@testable import JellyfinKit

// MARK: - Server address parsing

@Suite("Server URL normalisation")
struct ServerURLTests {
    @Test(
        "a bare LAN host gets http, which ATS permits",
        arguments: [
            ("192.168.1.10:8096", "http://192.168.1.10:8096"),
            ("10.0.0.5:8096", "http://10.0.0.5:8096"),
            ("172.16.3.1", "http://172.16.3.1"),
            ("jellyfin.local:8096", "http://jellyfin.local:8096"),
            ("localhost:8096", "http://localhost:8096"),
            ("jellyfin", "http://jellyfin"),
        ]
    )
    func bareLocalHost(_ input: String, _ expected: String) throws {
        let url = try JellyfinClient.normalizeServerURL(input)
        #expect(url.absoluteString == expected)
    }

    /// Regression: this used to become `http://music.example.net`, which ATS blocks
    /// outright — the connection failed before it was ever attempted.
    @Test(
        "a bare public host gets https, because ATS forbids plain HTTP to one",
        arguments: [
            ("music.example.net", "https://music.example.net"),
            ("jellyfin.example.com:8096", "https://jellyfin.example.com:8096"),
            ("example.com/jellyfin", "https://example.com/jellyfin"),
            ("172.32.0.1", "https://172.32.0.1"),
        ]
    )
    func barePublicHost(_ input: String, _ expected: String) throws {
        let url = try JellyfinClient.normalizeServerURL(input)
        #expect(url.absoluteString == expected)
    }

    @Test("an explicitly typed scheme always wins over the guess")
    func explicitSchemeWins() throws {
        let insecure = try JellyfinClient.normalizeServerURL("http://music.example.net")
        #expect(insecure.absoluteString == "http://music.example.net")
    }

    @Test("an explicit scheme is preserved")
    func explicitScheme() throws {
        let url = try JellyfinClient.normalizeServerURL("https://jellyfin.example.com")
        #expect(url.absoluteString == "https://jellyfin.example.com")
    }

    @Test("a reverse-proxy subpath survives")
    func subpath() throws {
        let url = try JellyfinClient.normalizeServerURL("https://example.com/jellyfin/")
        #expect(url.absoluteString == "https://example.com/jellyfin")
    }

    @Test("surrounding whitespace is forgiven")
    func whitespace() throws {
        let url = try JellyfinClient.normalizeServerURL("  jellyfin.local  ")
        #expect(url.absoluteString == "http://jellyfin.local")
    }

    @Test("garbage is rejected", arguments: ["", "   ", "ftp://example.com", "http://", "://nope"])
    func rejectsGarbage(_ raw: String) {
        #expect(throws: (any Error).self) {
            try JellyfinClient.normalizeServerURL(raw)
        }
    }
}

// MARK: - Path joining

@Suite("Request URL construction")
struct RequestURLTests {
    private func client(_ base: String) throws -> JellyfinClient {
        JellyfinClient(
            serverURL: try JellyfinClient.normalizeServerURL(base),
            device: .test
        )
    }

    @Test("paths append to a bare origin")
    func bareOrigin() throws {
        let url = try client("http://host:8096").url(path: "System/Info/Public")
        #expect(url.absoluteString == "http://host:8096/System/Info/Public")
    }

    @Test("paths append beneath a reverse-proxy prefix rather than replacing it")
    func proxyPrefix() throws {
        let url = try client("https://example.com/jellyfin").url(path: "System/Info/Public")
        #expect(url.absoluteString == "https://example.com/jellyfin/System/Info/Public")
    }

    @Test("query items are attached")
    func query() throws {
        let url = try client("http://host").url(
            path: "Items",
            query: [URLQueryItem(name: "userId", value: "abc")]
        )
        #expect(url.absoluteString == "http://host/Items?userId=abc")
    }
}

// MARK: - Auth header

@Suite("Authorization header")
struct AuthHeaderTests {
    @Test("includes the token when signed in")
    func withToken() {
        let header = DeviceProfile.test.headerValue(token: "secret")
        #expect(header.contains("Token=\"secret\""))
        #expect(header.hasPrefix("MediaBrowser "))
    }

    @Test("omits the token entirely when signed out")
    func withoutToken() {
        let header = DeviceProfile.test.headerValue(token: nil)
        #expect(!header.contains("Token"))
    }

    @Test("escapes quotes in a user-chosen device name, which would otherwise corrupt every request")
    func escapesQuotes() {
        let profile = DeviceProfile(
            client: "Aoide",
            device: #"Alex's "Best" iPhone"#,
            deviceId: "abc",
            version: "1.0"
        )
        let header = profile.headerValue(token: nil)
        #expect(header.contains(#"Device="Alex's \"Best\" iPhone""#))
    }
}

// MARK: - Decoding

@Suite("Response decoding")
struct DecodingTests {
    /// Jellyfin has shipped both casings; neither should break us.
    @Test("decodes PascalCase, as older servers send")
    func pascalCase() throws {
        let json = Data("""
        {
          "Items": [{
            "Id": "abc123",
            "Name": "Blue Monday",
            "Type": "Audio",
            "Album": "Power, Corruption & Lies",
            "AlbumId": "album1",
            "AlbumArtist": "New Order",
            "Artists": ["New Order"],
            "IndexNumber": 3,
            "ParentIndexNumber": 1,
            "RunTimeTicks": 44000000000,
            "AlbumPrimaryImageTag": "tag123",
            "UserData": { "IsFavorite": true, "PlayCount": 7 }
          }],
          "TotalRecordCount": 1,
          "StartIndex": 0
        }
        """.utf8)

        let response = try JSONDecoder.jellyfin.decode(ItemsResponse.self, from: json)
        let track = try #require(response.items.first)

        #expect(track.id == "abc123")
        #expect(track.name == "Blue Monday")
        #expect(track.type == .audio)
        #expect(track.albumArtist == "New Order")
        #expect(track.indexNumber == 3)
        #expect(track.userData?.isFavorite == true)
        #expect(track.userData?.playCount == 7)
        #expect(track.duration == .seconds(4400))
        #expect(response.totalRecordCount == 1)
    }

    @Test("decodes camelCase, as newer servers send")
    func camelCase() throws {
        let json = Data("""
        { "items": [{ "id": "x", "name": "Track", "type": "Audio" }], "totalRecordCount": 1 }
        """.utf8)
        let response = try JSONDecoder.jellyfin.decode(ItemsResponse.self, from: json)
        #expect(response.items.first?.name == "Track")
    }

    @Test("an unmodelled item type degrades to .unknown instead of failing the page")
    func unknownType() throws {
        let json = Data(#"{"Id":"x","Name":"A Movie","Type":"Movie"}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        #expect(item.type == .unknown)
    }

    @Test("a sparse item decodes with defaults rather than throwing")
    func sparseItem() throws {
        let json = Data(#"{"Id":"x"}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        #expect(item.name.isEmpty)
        #expect(item.artists.isEmpty)
        #expect(item.duration == nil)
    }
}

// MARK: - Artwork resolution

@Suite("Artwork source")
struct ArtworkTests {
    @Test("an item's own cover wins")
    func ownCover() throws {
        let json = Data(#"{"Id":"i","ImageTags":{"Primary":"own"},"AlbumId":"a","AlbumPrimaryImageTag":"alb"}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        let source = try #require(item.artworkSource)
        #expect(source == ("i", "own"))
    }

    @Test("a track with no cover of its own borrows the album's")
    func borrowsAlbumCover() throws {
        let json = Data(#"{"Id":"i","AlbumId":"a","AlbumPrimaryImageTag":"alb"}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        let source = try #require(item.artworkSource)
        #expect(source == ("a", "alb"))
    }

    @Test("no artwork anywhere resolves to nil, not a broken URL")
    func noCover() throws {
        let json = Data(#"{"Id":"i"}"#.utf8)
        let item = try JSONDecoder.jellyfin.decode(JellyfinItem.self, from: json)
        #expect(item.artworkSource == nil)
    }
}

// MARK: - Stream URLs

@Suite("Stream URLs")
struct StreamURLTests {
    private var signedIn: JellyfinClient {
        get throws {
            let serverURL = try JellyfinClient.normalizeServerURL("http://host:8096")
            return JellyfinClient(
                serverURL: serverURL,
                device: .test,
                credentials: JellyfinCredentials(
                    serverURL: serverURL,
                    userId: "user1",
                    username: "alex",
                    accessToken: "tok"
                )
            )
        }
    }

    @Test("carries the token as ApiKey, since AVPlayer can't send headers and api_key is legacy")
    func carriesToken() throws {
        let url = try signedIn.streamURL(for: "track1")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "ApiKey" && $0.value == "tok" })
        #expect(!query.contains { $0.name == "api_key" })
        #expect(url.path() == "/Audio/track1/universal")
    }

    @Test("a quality ceiling sets maxStreamingBitrate")
    func qualityCeiling() throws {
        let url = try signedIn.streamURL(for: "t", quality: .medium)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "maxStreamingBitrate" && $0.value == "320000" })
    }

    @Test("lossless sends no ceiling at all, so the server direct-plays")
    func losslessHasNoCeiling() throws {
        let url = try signedIn.streamURL(for: "t", quality: .lossless)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(!query.contains { $0.name == "maxStreamingBitrate" })
    }

    @Test("asking for a stream while signed out throws rather than building a 401")
    func signedOutThrows() throws {
        let client = JellyfinClient(
            serverURL: try JellyfinClient.normalizeServerURL("http://host"),
            device: .test
        )
        #expect(throws: JellyfinError.notSignedIn) {
            try client.streamURL(for: "t")
        }
    }
}

// MARK: - Helpers

extension DeviceProfile {
    static let test = DeviceProfile(
        client: "Aoide",
        device: "Test",
        deviceId: "test-device",
        version: "1.0"
    )
}

// MARK: - Offline lyrics storage

@Suite("Lyrics round trip")
struct LyricsCodableTests {
    private func decoded(_ json: String) throws -> LyricsTrack {
        LyricsTrack(try JSONDecoder.jellyfin.decode(LyricsDocument.self, from: Data(json.utf8)))
    }

    /// Downloaded lyrics are written as the domain model and read back later. If the
    /// two directions ever disagree, an offline track shows lyrics that are subtly
    /// wrong — and only offline, where it's hardest to notice.
    @Test("a synced track survives being written to disk and read back")
    func syncedRoundTrip() throws {
        let track = try decoded("""
        {"Lyrics":[
          {"Text":"First line","Start":10000000},
          {"Text":"Second line","Start":45000000}
        ]}
        """)

        let restored = try JSONDecoder().decode(
            LyricsTrack.self, from: JSONEncoder().encode(track)
        )

        #expect(restored == track)
        #expect(restored.isSynced)
        #expect(restored.lines[1].start == .seconds(4.5))
        // The binary search must still find the right line after a round trip.
        #expect(restored.index(at: .seconds(4.6)) == 1)
    }

    @Test("an untimed track keeps its nil starts rather than collapsing them to zero")
    func untimedRoundTrip() throws {
        let track = try decoded(#"{"Lyrics":[{"Text":"No timing here"}]}"#)

        let restored = try JSONDecoder().decode(
            LyricsTrack.self, from: JSONEncoder().encode(track)
        )

        #expect(restored == track)
        #expect(!restored.isSynced)
        #expect(restored.lines[0].start == nil)
    }

    @Test("per-word timings survive, so an enhanced-LRC download isn't silently downgraded")
    func wordTimingRoundTrip() throws {
        let track = try decoded("""
        {"Lyrics":[{"Text":"Hey now","Start":0,"Cues":[
          {"Position":0,"EndPosition":4,"Start":0},
          {"Position":4,"EndPosition":7,"Start":5000000}
        ]}]}
        """)

        let restored = try JSONDecoder().decode(
            LyricsTrack.self, from: JSONEncoder().encode(track)
        )

        #expect(restored == track)
        #expect(restored.hasWordTiming)
        #expect(restored.lines[0].words.map(\.text) == ["Hey", "now"])
    }
}

// MARK: - Structured queries

@Suite("Music query")
struct MusicQueryTests {
    private var signedIn: JellyfinClient {
        get throws {
            let serverURL = try JellyfinClient.normalizeServerURL("http://host:8096")
            return JellyfinClient(
                serverURL: serverURL,
                device: .test,
                credentials: JellyfinCredentials(
                    serverURL: serverURL, userId: "user1", username: "alex", accessToken: "tok"
                )
            )
        }
    }

    private func query(_ q: MusicQuery) throws -> [String: String] {
        let items = try signedIn.queryItems(for: q, includeTypes: ["Audio"], parentId: nil)
        return Dictionary(
            items.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test("a decade becomes the list of years Jellyfin filters on")
    func decade() {
        #expect(MusicQuery.years(from: 1990, to: 1999).count == 10)
        #expect(MusicQuery.years(from: 1990, to: 1999).first == 1990)
        #expect(MusicQuery.years(from: 1990, to: 1999).last == 1999)
    }

    @Test("a single year works from either end")
    func singleYear() {
        #expect(MusicQuery.years(from: 1994, to: 1994) == [1994])
    }

    /// A span this wide isn't a date filter, and truncating it would silently answer
    /// a narrower question than the one asked.
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

    /// Comma-separating these would split "Folk, World, & Country" into three
    /// genres that match nothing.
    @Test("genres are pipe-delimited")
    func genresArePiped() throws {
        let built = try query(MusicQuery(genres: ["Jazz", "Folk, World, & Country"]))
        #expect(built["genres"] == "Jazz|Folk, World, & Country")
    }

    @Test("an unconstrained query is recognised as empty, not as everything")
    func emptyMeansEmpty() {
        #expect(MusicQuery().isEmpty)
        #expect(!MusicQuery(genres: ["Jazz"]).isEmpty)
        #expect(!MusicQuery(favoritesOnly: true).isEmpty)
        #expect(!MusicQuery(searchTerm: "abc").isEmpty)
    }

    @Test("favourites become a filter, and are absent when not asked for")
    func favourites() throws {
        #expect(try query(MusicQuery(favoritesOnly: true))["filters"] == "IsFavorite")
        #expect(try query(MusicQuery(genres: ["Jazz"]))["filters"] == nil)
    }

    @Test("sort and direction reach the server")
    func sorting() throws {
        let built = try query(MusicQuery(genres: ["Jazz"], sort: .playCount, direction: .descending))
        #expect(built["sortBy"] == "PlayCount")
        #expect(built["sortOrder"] == "Descending")
    }

    @Test("the summary names what was understood")
    func summary() {
        let q = MusicQuery(genres: ["Rock"], years: Array(1990...1999), sort: .playCount)
        #expect(q.summary == "Rock · 1990–1999 · most played")
    }
}
