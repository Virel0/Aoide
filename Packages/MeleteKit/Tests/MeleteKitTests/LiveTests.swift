import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MeleteKit

/// Against a real Melete, when one is named: `MELETE_TEST_URL`, `MELETE_TEST_USER`
/// and `MELETE_TEST_PASSWORD` for a throwaway server with a music library (never
/// one with anyone's real account). Skipped when they aren't set.
@Suite("Against a real Melete", .enabled(if: ProcessInfo.processInfo.environment["MELETE_TEST_URL"] != nil))
struct LiveTests {
    @Test("signs in, lists, streams and signs out")
    func roundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        let url = try MeleteClient.normalizeServerURL(try #require(env["MELETE_TEST_URL"]))
        let anonymous = MeleteClient(
            serverURL: url,
            device: DeviceProfile(client: "Aoide", device: "MeleteKit live test", deviceId: "live", version: "1")
        )
        _ = try await anonymous.serverInfo()
        let (credentials, _) = try await anonymous.signIn(
            username: try #require(env["MELETE_TEST_USER"]),
            password: try #require(env["MELETE_TEST_PASSWORD"])
        )
        let client = anonymous.authenticated(as: credentials)

        let albums = try await client.albums(limit: 10)
        let first = try #require(albums.items.first, "the test server needs a music library")
        let (_, tracks) = try await client.album(id: first.id)
        let track = try #require(tracks.first)
        #expect(try await client.items(ids: [track.id]).first?.id == track.id)
        _ = try await client.lyrics(forItem: track.id)
        _ = try await client.musicGenres()
        _ = try await client.home()
        _ = try await client.search(first.name)

        let link = try await client.streamLink(forLazyURL: try client.streamURL(for: track.id))
        let (_, response) = try await URLSession.shared.data(from: link.url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        if let cover = client.artworkURL(for: first, maxWidth: 0), let authorization = client.authorization {
            var request = URLRequest(url: cover)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            let (_, coverResponse) = try await URLSession.shared.data(for: request)
            #expect((coverResponse as? HTTPURLResponse)?.statusCode == 200)
        }

        try await client.signOut()
        await #expect(throws: MeleteError.unauthorized) { try await client.musicGenres() }
    }
}
