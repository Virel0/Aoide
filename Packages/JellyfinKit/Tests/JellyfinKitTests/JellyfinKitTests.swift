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

    @Test("carries the token as api_key, since AVPlayer can't send headers")
    func carriesToken() throws {
        let url = try signedIn.streamURL(for: "track1")
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains { $0.name == "api_key" && $0.value == "tok" })
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
