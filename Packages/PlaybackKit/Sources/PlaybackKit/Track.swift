import Foundation

/// Everything the player needs to play and display one song.
///
/// Deliberately knows nothing about Jellyfin. The app maps `JellyfinItem` into this,
/// which keeps the queue logic testable without a server and leaves room for locally
/// downloaded files to become `Track`s with a `file://` stream URL.
public struct Track: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let album: String
    public let duration: Duration?
    /// Where the audio comes from — a remote stream or a downloaded file.
    public let streamURL: URL
    public let artworkURL: URL?
    /// Track number, used only for display.
    public let trackNumber: Int?

    public init(
        id: String,
        title: String,
        artist: String,
        album: String,
        duration: Duration?,
        streamURL: URL,
        artworkURL: URL? = nil,
        trackNumber: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.trackNumber = trackNumber
    }

    /// Two entries for the same song in one queue must stay distinguishable —
    /// a playlist can legitimately contain the same track twice, and removing one
    /// shouldn't remove both.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(streamURL)
    }
}

public enum RepeatMode: String, CaseIterable, Sendable {
    case off
    /// Loop the whole queue.
    case all
    /// Loop the current track.
    case one
}

public enum PlaybackState: Equatable, Sendable {
    case idle
    case buffering
    case playing
    case paused
    /// Playback stopped because something went wrong; the message is user-facing.
    case failed(String)

    public var isPlaying: Bool { self == .playing }
}
