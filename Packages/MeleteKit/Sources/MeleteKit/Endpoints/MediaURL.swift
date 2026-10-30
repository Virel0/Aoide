import Foundation

/// What Melete sends a track as. Lossless is the file untouched, which keeps
/// gapless joins exact; the others are converted whole on the server before the
/// link comes back (a second or two), then kept two days.
public enum StreamQuality: Sendable, CaseIterable, Identifiable {
    case low        // AAC 128 kbps — cellular in a dead zone
    case medium     // AAC 256 kbps
    case high       // AAC 320 kbps
    case lossless   // the file as it is

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .low: "Low (AAC 128 kbps)"
        case .medium: "Medium (AAC 256 kbps)"
        case .high: "High (AAC 320 kbps)"
        case .lossless: "Lossless"
        }
    }

    /// Its name in a lazy stream URL's query.
    var key: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .lossless: "lossless"
        }
    }

    init?(key: String) {
        guard let quality = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = quality
    }

    /// The `/play` request body. Never `spatial`: Atmos and multichannel tracks
    /// come folded into stereo.
    struct Body: Encodable {
        let format: String
        let bitrateKbps: Int?

        /// Lossless, for a file this device can't play as it is.
        static let flac = Body(format: "flac", bitrateKbps: nil)
    }

    var body: Body {
        switch self {
        case .low: Body(format: "aac", bitrateKbps: 128)
        case .medium: Body(format: "aac", bitrateKbps: 256)
        case .high: Body(format: "aac", bitrateKbps: 320)
        case .lossless: Body(format: "original", bitrateKbps: nil)
        }
    }
}

/// A link to play one track by: it carries its own token, works for 24 hours and
/// for this track only, serves byte ranges, and stops working when the session
/// that made it signs out.
public struct StreamLink: Sendable, Equatable {
    public let url: URL
    public let expiresAt: Date
    public let contentType: String
}

extension MeleteClient {
    /// The scheme of a stream URL whose real link is asked for only when the player
    /// starts loading it (see ``streamLink(forLazyURL:)``).
    public static let lazyStreamScheme = "melete-stream"

    /// A URL that stands for a track's stream until the player opens it. No request
    /// is made here: queueing a long list costs nothing.
    public func streamURL(for trackId: String, quality: StreamQuality = .lossless) throws -> URL {
        guard credentials != nil else { throw MeleteError.notSignedIn }
        var components = URLComponents()
        components.scheme = Self.lazyStreamScheme
        components.host = "track"
        components.path = "/\(trackId)"
        components.queryItems = [URLQueryItem(name: "quality", value: quality.key)]
        guard let url = components.url else { throw MeleteError.malformedServerURL(trackId) }
        return url
    }

    /// The track and quality a lazy stream URL stands for.
    public static func lazyStream(_ url: URL) -> (trackId: String, quality: StreamQuality)? {
        guard url.scheme == lazyStreamScheme, url.host() == "track",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let id = String(components.path.dropFirst())
        guard !id.isEmpty, !id.contains("/") else { return nil }
        let key = components.queryItems?.first { $0.name == "quality" }?.value ?? "lossless"
        return (id, StreamQuality(key: key) ?? .lossless)
    }

    /// Asks Melete for a link to stream a track by.
    ///
    /// `canPlay` says whether this device plays a content type. Lossless sends the
    /// file as it is, so a file the device can't open (Ogg on Apple's players,
    /// WavPack, Monkey's Audio) is asked for again as FLAC, which holds exactly what
    /// the file decodes to. The other qualities are AAC, which every device plays.
    public func streamLink(
        for trackId: String,
        quality: StreamQuality = .lossless,
        canPlay: @Sendable (String) -> Bool = { _ in true }
    ) async throws -> StreamLink {
        let link = try await requestLink(trackId, body: quality.body)
        guard quality == .lossless, !canPlay(link.contentType) else { return link }
        return try await requestLink(trackId, body: .flac)
    }

    private func requestLink(_ trackId: String, body: StreamQuality.Body) async throws -> StreamLink {
        struct Wire: Decodable {
            let streamUrl: String
            let expiresAt: Int64
            let contentType: String
        }
        let path = "api/v1/music/tracks/\(trackId)/play"
        let wire: Wire = try await post(path: path, body: body)
        // A path under the server's own address, as Melete gives it.
        guard let url = url(servedPath: wire.streamUrl) else {
            throw MeleteError.decoding(path: path, underlying: "the stream link isn't a path on this server")
        }
        return StreamLink(
            url: url,
            expiresAt: Date(timeIntervalSince1970: TimeInterval(wire.expiresAt)),
            contentType: wire.contentType
        )
    }

    /// The link a lazy stream URL stands for; `canPlay` as for
    /// ``streamLink(for:quality:canPlay:)``.
    public func streamLink(
        forLazyURL url: URL,
        canPlay: @Sendable (String) -> Bool = { _ in true }
    ) async throws -> StreamLink {
        guard let (id, quality) = Self.lazyStream(url) else {
            throw MeleteError.malformedServerURL(url.absoluteString)
        }
        return try await streamLink(for: id, quality: quality, canPlay: canPlay)
    }

    /// An album's cover. Fetching it needs ``authorization``; clients may keep a
    /// cover a day. Melete serves it at its own size, so `maxWidth` is unused.
    public func artworkURL(itemId albumId: String, tag: String? = nil, maxWidth: Int = 0) -> URL {
        url(path: "api/v1/music/albums/\(albumId)/cover")
    }

    /// The cover that stands for an item: an album's own, a track's album's.
    public func artworkURL(for item: MusicItem, maxWidth: Int) -> URL? {
        item.coverAlbumId.map { artworkURL(itemId: $0) }
    }

    /// Whether `url` is one of this server's, so a request to it may carry the
    /// token.
    public func isOwnURL(_ url: URL) -> Bool {
        url.scheme == serverURL.scheme && url.host() == serverURL.host() && url.port == serverURL.port
            && url.path().hasPrefix(serverURL.path())
    }
}
