import Foundation

/// How the engine tells the outside world what's happening, without PlaybackKit
/// itself knowing what is listening.
///
/// The app implements this to record plays in its curation store and to keep
/// Infinity's queue topped up.
public protocol PlaybackReporter: AnyObject, Sendable {
    func playbackDidStart(_ track: Track) async
    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async
    func playbackDidStop(_ track: Track, position: Duration) async
}

/// Loads cover art for the lock screen and the CarPlay now-playing view.
///
/// A closure rather than a hard dependency on an image cache, so the app can hand
/// over whatever it already uses without PlaybackKit importing it.
public typealias ArtworkLoader = @Sendable (URL) async -> Data?
