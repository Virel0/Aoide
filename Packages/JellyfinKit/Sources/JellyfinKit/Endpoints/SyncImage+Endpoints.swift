import Foundation

/// Playlist cover bytes, stored on the sidecar and addressed by their own SHA-256.
///
/// A separate channel from the op log on purpose. Payloads there cap at 256 KB and
/// every device replays the whole log, so images carried inside ops would make a full
/// history sync grow without bound — the one property the sync design rests on. The
/// row carries only a hash and a MIME type, which are a few dozen bytes and travel
/// through the ordinary log with no server change, because payloads are opaque.
///
/// Content-addressing earns three things: re-uploading the same bytes is a no-op
/// rather than a conflict, two playlists sharing a cover store one copy, and clients
/// may cache forever — bytes behind a hash cannot change, so there is no invalidation
/// problem to have.
public extension JellyfinClient {
    /// The MIME types the sidecar accepts. Anything else is refused with a 400.
    static let syncImageMimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    /// Uploads bytes under their own hash.
    ///
    /// Idempotent: sending the same bytes twice is accepted and changes nothing,
    /// which is what makes an interrupted upload safe to simply repeat.
    func uploadSyncImage(sha256: String, data: Data, mime: String) async throws {
        var request = request("PUT", path: Self.imagePath(sha256))
        request.httpBody = data
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        try await send(request, path: Self.imagePath(sha256))
    }

    /// Whether the server already holds these bytes.
    ///
    /// A HEAD rather than an upload-and-see: the whole point is to skip sending a
    /// cover that is already there, and on a phone connection that is the difference
    /// between a sync and a wait.
    func syncImageExists(sha256: String) async throws -> Bool {
        do {
            try await send(request("HEAD", path: Self.imagePath(sha256)), path: Self.imagePath(sha256))
            return true
        } catch JellyfinError.notFound {
            return false
        }
    }

    /// Fetches bytes by hash.
    ///
    /// Returned rather than exposed as a URL because every request needs the
    /// `MediaBrowser` header, and `AsyncImage` cannot send one — so these have to be
    /// fetched here and cached by the caller.
    func downloadSyncImage(sha256: String) async throws -> Data {
        try await send(request("GET", path: Self.imagePath(sha256)), path: Self.imagePath(sha256))
    }

    private static func imagePath(_ sha256: String) -> String { "aoide/images/\(sha256)" }
}
