import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The signed-in user's own account: their profile picture and password, and
/// for an admin, other users' passwords. Two-factor sign-in is in
/// `TwoFactor+Endpoints.swift`.
extension MeleteClient {
    /// The answer to every change of picture: its address now.
    private struct AvatarSet: Decodable { let avatarUrl: String? }

    /// Sets the profile picture from an image's bytes: `type` is
    /// `image/jpeg`, `image/png` or `image/webp`, up to 5 MB. Answers the
    /// picture's new path (``MeleteUser/avatarUrl``). HTTP 400 for bytes that
    /// aren't that type, or none; 413 over 5 MB.
    public func setAvatar(_ image: Data, type: String) async throws -> String? {
        let path = "api/v1/me/avatar"
        var request = request("PUT", path: path)
        request.httpBody = image
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        let data = try await send(request, path: path)
        return try decode(AvatarSet.self, from: data, path: path).avatarUrl
    }

    /// Sets the profile picture to a copy of a gallery picture. `.notFound`
    /// once it left the gallery; HTTP 422 when the server can't use it.
    public func setAvatar(galleryPicture id: String) async throws -> String? {
        struct Body: Encodable { let id: String }
        let path = "api/v1/me/avatar/gallery"
        let data = try await send(try jsonRequest("PUT", path: path, body: Body(id: id)), path: path)
        return try decode(AvatarSet.self, from: data, path: path).avatarUrl
    }

    /// Removes the profile picture; the name's initial stands in again.
    public func removeAvatar() async throws -> String? {
        let path = "api/v1/me/avatar"
        let data = try await send(request("DELETE", path: path), path: path)
        return try decode(AvatarSet.self, from: data, path: path).avatarUrl
    }

    /// The gallery's categories: Melete's own first, then the server's folders.
    public func avatarCategories() async throws -> [AvatarCategory] {
        struct Gallery: Decodable { let categories: [AvatarCategory] }
        let gallery: Gallery = try await get(path: "api/v1/avatars")
        return gallery.categories
    }

    /// A page of one category's pictures (`limit` 1 to 200).
    public func avatarPictures(in category: String, offset: Int = 0, limit: Int = 60) async throws -> AvatarPicturePage {
        try await get(path: "api/v1/avatars/pictures", query: [
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// Changes the signed-in user's password. Every other session and API key
    /// of theirs is signed out; this client's token stays good. A wrong current
    /// password is `.wrong(.password)`; HTTP 400 for a new one outside 8 to
    /// 1,024 characters; 429 after too many wrong passwords.
    public func changePassword(current: String, new: String) async throws {
        struct Body: Encodable { let currentPassword: String; let newPassword: String }
        do {
            try await sendIgnoringResponse("PUT", path: "api/v1/me/password", body: Body(currentPassword: current, newPassword: new))
        } catch MeleteError.forbidden {
            // Melete says only "current password is wrong" here, not which
            // secret: there's one.
            throw MeleteError.wrong(.password)
        }
    }

    /// Every user, with whether they're an admin. Admins only (`.forbidden`).
    public func users() async throws -> [MeleteUser] {
        try await get(path: "api/v1/users")
    }

    /// Gives another user a new generated password, shown only in this answer;
    /// they are signed out everywhere. Admins only. `.notFound` for no such
    /// user; HTTP 409 for your own account.
    public func giveNewPassword(toUser id: String) async throws -> GivenPassword {
        try await post(path: "api/v1/users/\(id)/password")
    }
}
