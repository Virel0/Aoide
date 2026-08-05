import Foundation
import JellyfinKit
import PlaybackKit
import os

/// Joins the two packages together: turns Jellyfin items into playable tracks, and
/// feeds the engine's playback events back to the server.
///
/// Neither package knows about the other — JellyfinKit has no idea what a player is,
/// PlaybackKit has no idea what a server is. This is the only file that knows both.
@MainActor
enum JellyfinPlaybackBridge {
    /// Artwork size for the lock screen and CarPlay. Both render around 600pt on the
    /// largest displays; asking for more just wastes bandwidth on a car connection.
    private static let nowPlayingArtworkWidth = 600

    /// Connects the shared engine to the signed-in client. Safe to call again after
    /// a sign-in change — it replaces the previous wiring.
    static func connect(engine: PlaybackEngine = .shared, client: JellyfinClient) {
        let reporter = JellyfinReporter(client: client)
        engine.reporter = reporter
        Self.retainedReporter = reporter

        engine.artworkLoader = { url in
            // A plain data task: artwork URLs already carry the auth token and an
            // image tag, so URLSession's own cache handles repeats correctly.
            try? await URLSession.shared.data(from: url).0
        }
    }

    static func disconnect(engine: PlaybackEngine = .shared) {
        engine.clearQueue()
        engine.reporter = nil
        Self.retainedReporter = nil
    }

    /// The engine holds its reporter weakly so it can't keep a stale signed-out
    /// client alive; something has to own it, and that's here.
    private static var retainedReporter: JellyfinReporter?

    // MARK: - Mapping

    /// Converts Jellyfin items into playable tracks, dropping anything that isn't
    /// audio or that we can't build a stream URL for.
    static func tracks(from items: [JellyfinItem], client: JellyfinClient, quality: StreamQuality = .lossless) -> [Track] {
        items.compactMap { item in
            guard item.type == .audio else { return nil }
            guard let streamURL = try? client.streamURL(for: item.id, quality: quality) else { return nil }

            return Track(
                id: item.id,
                title: item.name,
                artist: item.albumArtist ?? item.artists.first ?? "Unknown Artist",
                album: item.album ?? "",
                duration: item.duration,
                streamURL: streamURL,
                artworkURL: client.artworkURL(for: item, maxWidth: nowPlayingArtworkWidth),
                trackNumber: item.indexNumber
            )
        }
    }
}

/// Posts the engine's events to `/Sessions/Playing*`.
private final class JellyfinReporter: PlaybackReporter {
    private let client: JellyfinClient
    private let log = Logger(subsystem: "com.example.jellymusic", category: "reporting")

    init(client: JellyfinClient) {
        self.client = client
    }

    func playbackDidStart(_ track: Track) async {
        await attempt("start") {
            try await client.reportPlaybackStarted(itemId: track.id)
        }
    }

    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async {
        await attempt("progress") {
            try await client.reportPlaybackProgress(itemId: track.id, position: position, isPaused: isPaused)
        }
    }

    func playbackDidStop(_ track: Track, position: Duration) async {
        await attempt("stop") {
            try await client.reportPlaybackStopped(itemId: track.id, position: position)
        }
    }

    /// Reporting is best-effort bookkeeping. A failure here must never interrupt
    /// playback — losing a play count matters far less than the music stopping.
    private func attempt(_ label: String, _ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            log.debug("Playback \(label, privacy: .public) report failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
