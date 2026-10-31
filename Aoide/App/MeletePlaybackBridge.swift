import Foundation
import MeleteKit
import PlaybackKit
import os

/// Joins the packages together: turns Melete's tracks into playable ones, and feeds
/// the engine's playback events to the local curation store, whose play events sync
/// to Melete.
///
/// None of them knows about the others — MeleteKit has no idea what a player is,
/// PlaybackKit has no idea what a server is, CurationKit has no idea either exists.
/// This is the only file that knows all three.
@MainActor
enum MeletePlaybackBridge {
    /// Artwork size for the lock screen and CarPlay. Both render around 600pt on the
    /// largest displays; asking for more just wastes bandwidth on a car connection.

    /// Connects the shared engine to the signed-in client. Safe to call again after
    /// a sign-in change — it replaces the previous wiring.
    static func connect(engine: PlaybackEngine = .shared, client: MeleteClient) {
        // The local store draws its conclusions from the events — chiefly whether a
        // track was listened to or skipped — and its play events are how Melete
        // learns what was played.
        let reporter = PlaybackReporters([Self.recorder, InfinityQueue.shared])
        engine.reporter = reporter
        Self.retainedReporter = reporter

        // A streamed track's link is asked for when the player opens it.
        StreamLinkLoader.shared.use(client)
        ListenTogetherCoordinator.shared.connect(client: client)
        engine.assetMaker = { StreamLinkLoader.shared.asset(for: $0) }

        let authorization = client.authorization
        engine.artworkLoader = { url in
            // Melete's covers need the token; nothing else is sent it.
            var request = URLRequest(url: url)
            if client.isOwnURL(url), let authorization {
                request.setValue(authorization, forHTTPHeaderField: "Authorization")
            }
            return try? await URLSession.shared.data(for: request).0
        }
        ArtworkCache.shared.use(client)
    }

    static func disconnect(engine: PlaybackEngine = .shared) {
        // Emptying the queue reports a stop first, so the play in progress is closed
        // out against the reporter that is still attached.
        engine.clearQueue()
        engine.reporter = nil
        Self.retainedReporter = nil
        StreamLinkLoader.shared.use(nil)
        ListenTogetherCoordinator.shared.connect(client: nil)
        ArtworkCache.shared.use(nil)

        // None of what was queued belongs to whoever signs in next.
        PlaybackContext.clear()
        let recorder = Self.recorder
        Task { await recorder.clearSavedQueue() }
    }

    /// The engine holds its reporter weakly so it can't keep a stale signed-out
    /// client alive; something has to own it, and that's here.
    private static var retainedReporter: PlaybackReporters?

    /// Outlives any one session: it writes to a local database rather than to a
    /// server, and it has to be reachable from `disconnect` after the client is gone.
    private static let recorder = CurationRecorder()

    // MARK: - Mapping

    /// Converts Melete's tracks into playable ones, and reports which source rows
    /// survived.
    ///
    /// The indices matter: a caller that says "start at row 4" is addressing the
    /// list the user tapped, and dropping an unplayable row above it shifts every
    /// position below. Returning both together keeps the filter predicate in one
    /// place rather than duplicated at each call site where it could drift.
    static func playableTracks(
        from items: [MusicItem],
        client: MeleteClient,
        quality: StreamQuality = .lossless
    ) -> (tracks: [Track], sourceIndices: [Int]) {
        // The last moment the full items are in hand. A `Track` carries what the player
        // needs; the genre, the year and the track artist held apart from the album
        // artist all stop here unless something remembers them, and the local history is
        // the thing that later wants to join against them offline.
        PlaybackContext.remember(items)

        var tracks: [Track] = []
        var indices: [Int] = []
        for (index, item) in items.enumerated() {
            guard let track = track(from: item, client: client, quality: quality) else { continue }
            tracks.append(track)
            indices.append(index)
        }
        return (tracks, indices)
    }

    /// Converts Melete's tracks into playable ones, dropping anything that isn't
    /// audio or that we can't build a stream URL for.
    static func tracks(from items: [MusicItem], client: MeleteClient, quality: StreamQuality = .lossless) -> [Track] {
        playableTracks(from: items, client: client, quality: quality).tracks
    }

    /// The single definition of "can this be played". Both public entry points go
    /// through it so the predicate can't drift between them.
    private static func track(from item: MusicItem, client: MeleteClient, quality: StreamQuality) -> Track? {
        guard item.type == .audio else { return nil }

        // A downloaded copy wins over the network every time. This is the whole
        // point of downloading: in a car with no signal the stream URL would simply
        // fail, and the local file is also gapless where a transcode would not be.
        let source: URL
        var sound: SilenceBounds?
        if let local = DownloadStore.localURLIfPresent(for: item.id) {
            source = local
            // Only for downloads: the phone can only measure what it holds. A
            // streamed track plays whole until the server can say where its sound is.
            if TrimSilencePreference.isOn { sound = SilenceIndex.shared.bounds(for: item.id) }
        } else if let streamURL = try? client.streamURL(for: item.id, quality: quality) {
            source = streamURL
        } else {
            return nil
        }

        return Track(
            id: item.id,
            title: item.name,
            artist: item.albumArtist ?? item.artists.first ?? "Unknown Artist",
            album: item.album ?? "",
            duration: item.duration,
            streamURL: source,
            artworkURL: client.artworkURL(for: item, maxWidth: Design.ArtworkWidth.player),
            trackNumber: item.trackNumber,
            sound: sound
        )
    }
}

/// Hands every engine event to more than one reporter.
///
/// The engine has one reporter slot, and two things want the events. Fanning out
/// *concurrently* rather than in turn is the part that matters: a top-up that sits
/// on the network must not hold the local history back from the moment it
/// describes — and, worse, let a start overtake the stop in front of it and close
/// the wrong play.
private final class PlaybackReporters: PlaybackReporter {
    private let reporters: [any PlaybackReporter]

    init(_ reporters: [any PlaybackReporter]) {
        self.reporters = reporters
    }

    func playbackDidStart(_ track: Track) async {
        await fanOut { await $0.playbackDidStart(track) }
    }

    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async {
        await fanOut { await $0.playbackDidProgress(track, position: position, isPaused: isPaused) }
    }

    func playbackDidStop(_ track: Track, position: Duration) async {
        await fanOut { await $0.playbackDidStop(track, position: position) }
    }

    private func fanOut(_ body: @escaping @Sendable (any PlaybackReporter) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for reporter in reporters {
                group.addTask { await body(reporter) }
            }
        }
    }
}
