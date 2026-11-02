import Foundation

/// Whether motion covers are made and shown, as `/api/v1/music/motion-covers`
/// says.
public struct MotionCoverChoice: Decodable, Equatable, Sendable {
    /// Whether this user sees the motion covers Melete made from still covers.
    public let showGenerated: Bool
    /// Whether the server makes motion covers at all (an admin's setting). Those
    /// in an album's own folder are shown either way.
    public let on: Bool
}

extension MeleteClient {
    // MARK: - Motion covers

    /// The largest motion cover read: a loop of a few seconds is far smaller.
    public static let motionCoverMaxBytes = 32 * 1024 * 1024

    /// An album's looping video, from the path its album gave
    /// (``MusicItem/motionCover``). Nil for a path that isn't the server's own,
    /// or one larger than ``motionCoverMaxBytes``.
    public func motionCoverData(servedPath: String) async throws -> Data? {
        guard let url = url(servedPath: servedPath) else { return nil }
        var request = URLRequest(url: url)
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let data = try await send(request, path: servedPath)
        return data.count <= Self.motionCoverMaxBytes ? data : nil
    }

    /// Whether `data` is a video this platform plays: MP4 or QuickTime (an
    /// `ftyp` box), not WebM.
    public static func isPlayableMotionCover(_ data: Data) -> Bool {
        data.count > 8 && data[data.startIndex + 4 ..< data.startIndex + 8] == Data("ftyp".utf8)
    }

    /// Whether motion covers are on, and whether this user sees those Melete made.
    public func motionCoverChoice() async throws -> MotionCoverChoice {
        try await get(path: "api/v1/music/motion-covers")
    }

    /// Shows or hides the motion covers Melete made from still covers, for this
    /// user on every device.
    @discardableResult
    public func setShowsGeneratedMotionCovers(_ shows: Bool) async throws -> MotionCoverChoice {
        struct Change: Encodable { let showGenerated: Bool }
        let path = "api/v1/music/motion-covers"
        let data = try await send(try jsonRequest("PUT", path: path, body: Change(showGenerated: shows)), path: path)
        return try decode(MotionCoverChoice.self, from: data, path: path)
    }
}
