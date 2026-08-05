import Foundation

/// How much bandwidth to spend on a stream. Jellyfin transcodes down to the ceiling
/// when the source exceeds it, and direct-plays untouched when it doesn't.
/// How much bandwidth to spend on a stream.
///
/// Anything other than ``lossless`` sets a ceiling, and a ceiling makes the server
/// transcode — which reintroduces the gap between tracks. Gapless playback and a
/// bitrate cap are mutually exclusive.
public enum StreamQuality: Sendable, CaseIterable, Identifiable {
    case low        // 128 kbps — cellular in a dead zone
    case medium     // 320 kbps
    case high       // 1.5 Mbps — most lossy sources direct-play
    case lossless   // no ceiling; direct play whatever is on disk

    public var id: Self { self }

    public var bitrate: Int? {
        switch self {
        case .low: 128_000
        case .medium: 320_000
        case .high: 1_500_000
        case .lossless: nil
        }
    }

    public var displayName: String {
        switch self {
        case .low: "Low (128 kbps)"
        case .medium: "Medium (320 kbps)"
        case .high: "High (1.5 Mbps)"
        case .lossless: "Lossless"
        }
    }
}

extension JellyfinClient {
    /// A playable audio URL.
    ///
    /// Uses `/Audio/{id}/universal`, which lets the *server* decide between direct
    /// play and transcoding based on what we say we can decode — rather than us
    /// guessing per-file and getting it wrong on the one FLAC that isn't seekable.
    ///
    /// The token travels as `api_key` because `AVPlayer` gives us no reliable way to
    /// attach an `Authorization` header to the segment requests it makes internally.
    public func streamURL(for itemId: String, quality: StreamQuality = .lossless) throws -> URL {
        guard let credentials else { throw JellyfinError.notSignedIn }

        var query = [
            URLQueryItem(name: "userId", value: credentials.userId),
            URLQueryItem(name: "deviceId", value: device.deviceId),
            URLQueryItem(name: "api_key", value: credentials.accessToken),
            // Containers iOS decodes natively, so the server hands the file over
            // untouched. `alac` is deliberately absent: ALAC is a codec that lives
            // inside m4a, not a Jellyfin container, so listing it matches nothing.
            URLQueryItem(name: "container", value: "mp3,aac,m4a,m4b,flac,wav,aiff"),
            URLQueryItem(name: "audioCodec", value: "aac"),
            // Progressive HTTP rather than HLS. HLS segments carry no packet table,
            // which costs ~62ms of silence at every track boundary and cannot be
            // recovered on the client — it alone would rule out gapless playback.
            URLQueryItem(name: "transcodingContainer", value: "mp4"),
            URLQueryItem(name: "transcodingProtocol", value: "http"),
        ]
        // A bitrate ceiling forces the server to transcode even a source iOS could
        // have played directly, which reintroduces the boundary gap. Only lossless
        // leaves the file alone.
        if let bitrate = quality.bitrate {
            query.append(URLQueryItem(name: "maxStreamingBitrate", value: String(bitrate)))
        }
        return url(path: "Audio/\(itemId)/universal", query: query)
    }

    /// Artwork URL sized for a specific rendering.
    ///
    /// Pass the item's image tag: Jellyfin includes it in the URL, so a changed cover
    /// yields a different URL and every HTTP cache invalidates itself for free.
    public func artworkURL(
        itemId: String,
        tag: String?,
        maxWidth: Int,
        quality: Int = 90
    ) -> URL {
        var query = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: String(quality)),
        ]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        return url(path: "Items/\(itemId)/Images/Primary", query: query)
    }

    /// Convenience over ``artworkURL(itemId:tag:maxWidth:quality:)`` that resolves a
    /// track's borrowed album artwork for you. `nil` when the item has no cover at all.
    public func artworkURL(for item: JellyfinItem, maxWidth: Int) -> URL? {
        guard let source = item.artworkSource else { return nil }
        return artworkURL(itemId: source.itemId, tag: source.tag, maxWidth: maxWidth)
    }
}
