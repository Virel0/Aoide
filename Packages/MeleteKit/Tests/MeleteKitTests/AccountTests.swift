import Foundation
import Testing
@testable import MeleteKit

@Suite("Your account")
struct AccountTests {
    private static let picture = "/api/v1/users/1/avatar?v=0123456789ab"

    @Test("a photo is sent as itself with its type; the answer is the picture's path")
    func upload() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let client = StubServer.client(host: "upload.test") { request, body in
            guard request.httpMethod == "PUT", request.url?.path() == "/api/v1/me/avatar",
                  request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg", body == jpeg
            else { return (400, Fixture.json(["error": "not an image"])) }
            return (200, Fixture.json(["avatar_url": Self.picture]))
        }
        #expect(try await client.setAvatar(jpeg, type: "image/jpeg") == Self.picture)
        await #expect(throws: MeleteError.http(status: 400, path: "api/v1/me/avatar", detail: "not an image")) {
            try await client.setAvatar(Data(), type: "image/jpeg")
        }
    }

    @Test("the gallery lists categories and pages; a picture is set by its id; removing answers none")
    func gallery() async throws {
        let client = StubServer.client(host: "gallery.test") { request, body in
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/v1/avatars"):
                return (200, Fixture.json(["categories": [["id": "official", "name": "Melete", "count": 16]]]))
            case ("GET", "/api/v1/avatars/pictures"):
                guard request.query("category") == "official", request.query("offset") == "60" else { return (404, Data()) }
                return (200, Fixture.json([
                    "total": 61,
                    "pictures": [["id": "official/flame.webp", "url": "/api/v1/avatars/picture?id=official%2Fflame.webp"]],
                ]))
            case ("PUT", "/api/v1/me/avatar/gallery"):
                let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
                return sent?["id"] == "official/flame.webp"
                    ? (200, Fixture.json(["avatar_url": Self.picture]))
                    : (404, Fixture.json(["error": "no such picture"]))
            case ("DELETE", "/api/v1/me/avatar"):
                return (200, Fixture.json(["avatar_url": NSNull()]))
            default:
                return (500, Data())
            }
        }
        #expect(try await client.avatarCategories().map(\.name) == ["Melete"])
        let page = try await client.avatarPictures(in: "official", offset: 60)
        #expect(page.total == 61 && page.pictures.map(\.id) == ["official/flame.webp"])
        let shown = try #require(client.avatarURL(page.pictures[0].url))
        #expect(shown.path() == "/api/v1/avatars/picture" && client.isOwnURL(shown))
        #expect(URLComponents(url: shown, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "official/flame.webp")
        #expect(try await client.setAvatar(galleryPicture: "official/flame.webp") == Self.picture)
        await #expect(throws: MeleteError.notFound(path: "api/v1/me/avatar/gallery")) {
            try await client.setAvatar(galleryPicture: "official/gone.webp")
        }
        #expect(try await client.removeAvatar() == nil)
    }

    @Test("a password change sends both; a wrong current one is a wrong password")
    func password() async throws {
        let client = StubServer.client(host: "password.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            guard request.httpMethod == "PUT", request.url?.path() == "/api/v1/me/password" else { return (404, Data()) }
            switch (sent?["current_password"], sent?["new_password"]) {
            case ("old-secret", let new?) where new.count >= 8: return (204, Data())
            case ("old-secret", _): return (400, Fixture.json(["error": "passwords are 8 to 1024 characters"]))
            default: return (403, Fixture.json(["error": "current password is wrong"]))
            }
        }
        try await client.changePassword(current: "old-secret", new: "new-secret")
        await #expect(throws: MeleteError.wrong(.password)) {
            try await client.changePassword(current: "guess", new: "new-secret")
        }
        do {
            try await client.changePassword(current: "old-secret", new: "short")
            Issue.record("a short password was taken")
        } catch MeleteError.http(status: 400, _, _) {}
    }

    @Test("an admin lists users with who's an admin, and gives one a new password")
    func admin() async throws {
        let client = StubServer.client(host: "admin.test") { request, _ in
            switch (request.httpMethod, request.url?.path()) {
            case ("GET", "/api/v1/users"):
                return (200, Fixture.json([
                    ["id": 1, "username": "alex", "is_admin": true, "avatar_url": NSNull()],
                    ["id": 2, "username": "bo", "is_admin": false, "avatar_url": Self.picture],
                ]))
            case ("POST", "/api/v1/users/2/password"):
                return (200, Fixture.json(["username": "bo", "password": "generated-pass"]))
            case ("POST", "/api/v1/users/1/password"):
                return (409, Fixture.json(["error": "that's your own account"]))
            default:
                return (403, Fixture.json(["error": "admins only"]))
            }
        }
        let users = try await client.users()
        #expect(users.map(\.isAdmin) == [true, false] && users.map(\.id) == ["1", "2"])
        let given = try await client.giveNewPassword(toUser: "2")
        #expect(given.username == "bo" && given.password == "generated-pass")
        do {
            _ = try await client.giveNewPassword(toUser: "1")
            Issue.record("an admin reset their own password here")
        } catch MeleteError.http(status: 409, _, _) {}
    }

    @Test("/me says whether you're an admin; the directory doesn't, and leaves it off")
    func meIsAdmin() async throws {
        let client = StubServer.client(host: "me-admin.test") { request, _ in
            request.url?.path() == "/api/v1/me"
                ? (200, Fixture.json(["id": 1, "username": "alex", "is_admin": true, "sees_all_music": true, "avatar_url": NSNull()]))
                : (200, Fixture.json([["id": 1, "username": "alex"]]))
        }
        let me = try await client.me()
        #expect(me.isAdmin)
        #expect(me.with(avatarUrl: Self.picture).isAdmin && me.with(avatarUrl: Self.picture).avatarUrl == Self.picture)
        #expect(try await client.userDirectory().first?.isAdmin == false)
    }

    @Test("a 403 without a reason is still forbidden")
    func plainForbidden() async throws {
        let client = StubServer.client(host: "forbidden.test") { _, _ in (403, Fixture.json(["error": "admins only"])) }
        await #expect(throws: MeleteError.forbidden) { try await client.users() }
    }
}
