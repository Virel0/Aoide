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

    /// Converts Jellyfin items into playable tracks, and reports which source rows
    /// survived.
    ///
    /// The indices matter: a caller that says "start at row 4" is addressing the
    /// list the user tapped, and dropping an unplayable row above it shifts every
    /// position below. Returning both together keeps the filter predicate in one
    /// place rather than duplicated at each call site where it could drift.
    static func playableTracks(
        from items: [JellyfinItem],
        client: JellyfinClient,
        quality: StreamQuality = .lossless
    ) -> (tracks: [Track], sourceIndices: [Int]) {
        var tracks: [Track] = []
        var indices: [Int] = []
        for (index, item) in items.enumerated() {
            guard let track = track(from: item, client: client, quality: quality) else { continue }
            tracks.append(track)
            indices.append(index)
        }
        return (tracks, indices)
    }

    /// Converts Jellyfin items into playable tracks, dropping anything that isn't
    /// audio or that we can't build a stream URL for.
    static func tracks(from items: [JellyfinItem], client: JellyfinClient, quality: StreamQuality = .lossless) -> [Track] {
        playableTracks(from: items, client: client, quality: quality).tracks
    }

    /// The single definition of "can this be played". Both public entry points go
    /// through it so the predicate can't drift between them.
    private static func track(from item: JellyfinItem, client: JellyfinClient, quality: StreamQuality) -> Track? {
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

/// Posts the engine's events to `/Sessions/Playing*`.
private final class JellyfinReporter: PlaybackReporter {
    private let client: JellyfinClient
    private let log = Logger(subsystem: "com.example.aoide", category: "reporting")

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
