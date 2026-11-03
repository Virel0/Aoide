import Foundation
import Testing
@testable import MeleteKit

@Suite("Profile pictures")
struct AvatarTests {
    private static let path = "/api/v1/users/2/avatar?v=0123456789ab"

    @Test("the directory and /me carry the picture; a server without pictures still decodes")
    func decoding() async throws {
        let client = StubServer.client(host: "avatars.test") { request, _ in
            switch request.url?.path() {
            case "/api/v1/users/directory":
                return (200, Fixture.json([
                    ["id": 2, "username": "alice", "avatar_url": Self.path],
                    ["id": 3, "username": "bo", "avatar_url": NSNull()],
                    ["id": 4, "username": "cy"],
                ]))
            case "/api/v1/me":
                return (200, Fixture.json([
                    "id": 2, "username": "alice", "is_admin": false, "sees_all_music": true, "avatar_url": Self.path,
                ]))
            default:
                return (404, Data())
            }
        }
        let people = try await client.userDirectory()
        #expect(people.map(\.name) == ["alice", "bo", "cy"])
        #expect(people.map(\.avatarUrl) == [Self.path, nil, nil])
        #expect(try await client.me().avatarUrl == Self.path)
    }

    @Test("sign-in decodes a user without a picture")
    func signInWithout() async throws {
        let client = StubServer.client(host: "avatar-signin.test") { _, _ in (200, Fixture.session(3, "alex")) }
        let (_, user) = try await client.signedOut().signIn(username: "alex", password: "pw")
        #expect(user.avatarUrl == nil)
    }

    @Test("a member of a session carries a picture when the server sends one")
    func member() throws {
        let members = try JSONDecoder.melete.decode([ListenMember].self, from: Fixture.json([
            ["username": "alice", "device": "Desk", "you": false, "avatar_url": Self.path],
            ["username": "bo", "device": "Phone", "you": true],
        ]))
        #expect(members.map(\.avatarUrl) == [Self.path, nil])
    }

    @Test("a picture's address keeps the proxy prefix and its version, and is the server's own")
    func address() throws {
        let client = StubServer.client(host: "avatar-url.test", path: "/melete") { _, _ in (404, Data()) }
        let url = try #require(client.avatarURL(Self.path))
        #expect(url.absoluteString == "http://avatar-url.test/melete/api/v1/users/2/avatar?v=0123456789ab")
        #expect(client.isOwnURL(url))
        #expect(client.avatarURL("/api/v1/users/2/avatar")?.query() == nil)
    }

    @Test(
        "no picture, or one that isn't a path on this server, has no address",
        arguments: [nil, "", "https://elsewhere.example/a.png", "//elsewhere.example/a", "/api/../admin", "/api/a?v=1#x", "/api/a?"]
    )
    func noAddress(_ path: String?) {
        let client = StubServer.client(host: "avatar-none.test") { _, _ in (404, Data()) }
        #expect(client.avatarURL(path) == nil)
    }
}
