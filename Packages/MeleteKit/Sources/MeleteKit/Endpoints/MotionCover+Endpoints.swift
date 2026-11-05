import Foundation

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
}
