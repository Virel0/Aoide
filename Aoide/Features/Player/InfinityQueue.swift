import CurationKit
import MeleteKit
import PlaybackKit
import SwiftUI
import os

/// Infinity: keeps the music going when the queue runs out.
///
/// Off by default — a queue that ends is not a fault, and a player that quietly
/// plays on for an hour after the album finished is one nobody asked for.
///
/// What it finds comes from Melete's `/aoide/next`, which scores the whole
/// library against whatever is playing — see `docs/infinity.md` and
/// ``NextChooser``. A server without it answers 404, and Infinity rests for the
/// session.
@MainActor
@Observable
final class InfinityQueue: PlaybackReporter {
    static let shared = InfinityQueue()

    static let key = "aoide.infinity"

    /// Top up when fewer than this many songs are left in front of the listener.
    /// Far enough ahead that Up Next is never a dead end to look at, close enough
    /// that a station's worth of songs is not fetched for a queue somebody was
    /// about to clear.
    static let minimumAhead = 3

    /// How many to add each time. A handful of songs, not a shift's worth: the
    /// seed moves on as the queue plays, so asking again later gives something
    /// that follows what is playing *then*.
    static let batch = 20

    private let log = Logger(subsystem: AppIdentity.bundle, category: "infinity")

    /// The switch as the listener set it. Read ``isOn`` for what is in force.
    private(set) var isChosen: Bool = UserDefaults.standard.bool(forKey: InfinityQueue.key)

    /// Whether the queue keeps going.
    ///
    /// Auto DJ implies it. A set that ends is not a set, and somebody who put
    /// a DJ on did not ask for silence when the playlist ran out — so with Auto
    /// DJ on, Infinity is on, whatever its own switch says. The switch keeps
    /// its own answer for when Auto DJ goes off again.
    var isOn: Bool { isChosen || AutoDJPreference.isOn }

    /// One fetch at a time. Track changes and the toggle can both ask at once,
    /// and two stations arriving would double every top-up.
    private var isFetching = false

    /// Whether the server is asked. Turned off for the session by a 404 from
    /// `/aoide/next`, which is what a server without it answers.
    private(set) var sidecarChooses = true

    /// Why each record the server chose is where it is, by track id, for
    /// the queue to show. Kept for records still queued; nothing is ever
    /// removed, and a session's worth of these is a few kilobytes.
    private(set) var reasons: [String: NextChooser.Factors] = [:]

    /// How many finished plays the sidecar's taste stood on, last time it
    /// answered. Zero means it is still learning what this listener likes.
    private(set) var tasteEvents: Int?

    private init() {}

    func setOn(_ on: Bool) {
        isChosen = on
        UserDefaults.standard.set(on, forKey: Self.key)
        if isOn { Task { await topUpIfNeeded() } }
    }

    /// Auto DJ was just switched on: the queue should start filling now rather
    /// than at the next track change.
    func autoDJChanged() {
        if isOn { Task { await topUpIfNeeded() } }
    }

    /// Adds more songs if the queue is nearly out of them.
    func topUpIfNeeded() async {
        guard isOn, !isFetching else { return }
        // Every device in a listening-together session would add songs of its own.
        guard !ListenTogetherCoordinator.shared.isInSession else { return }

        let engine = PlaybackEngine.shared
        // A looping queue never runs out, so there is nothing to rescue — and
        // filling it would quietly turn a loop into something else.
        guard engine.repeatMode == .off else { return }
        guard let seed = engine.queue.currentTrack else { return }
        guard engine.queue.upNext.count < Self.minimumAhead else { return }
        guard let client = AppSession.shared.client else { return }

        isFetching = true
        defer { isFetching = false }

        let known = Set(engine.queue.entries.map(\.track.id))

        if sidecarChooses, let chosen = await askSidecar(seed: seed, client: client, known: known) {
            let tracks = MeletePlaybackBridge.playableTracks(from: chosen, client: client).tracks
            guard !tracks.isEmpty else { return }
            engine.extendQueue(tracks)
            // Fetched now rather than waited for: the first hand-over is at
            // least a record away, and the decks ask again when they book.
            if AutoDJPreference.isOn {
                BeatGridSync.shared.prefetch(ids: tracks.map(\.id))
                ArrangementSync.shared.prefetch(ids: tracks.map(\.id))
            }
            log.info("Infinity added \(tracks.count) songs after \(seed.title, privacy: .public), chosen by the server")
            return
        }

        log.info("Infinity found nothing new to add after \(seed.title, privacy: .public)")
    }

    /// Asks the server what should follow `seed`, from the whole library.
    ///
    /// Nothing on a 404 — a server without the route, remembered for the
    /// session — or on any other failure, which is logged: the queue then simply
    /// ends, as it would have anyway. What comes back is in the server's order
    /// and is kept in it.
    private func askSidecar(seed: Track, client: MeleteClient, known: Set<String>) async -> [MusicItem]? {
        let engine = PlaybackEngine.shared
        let recent = (try? CurationDatabase.shared?.recentlyPlayed(limit: NextChooser.Request.maxRecent)) ?? []
        let request = NextChooser.Request(
            seed: seed.id,
            queue: engine.queue.upNext.map(\.track.id),
            recent: recent,
            mode: AutoDJPreference.isOn ? .autodj : .infinity,
            limit: Self.batch
        )
        do {
            let response = try NextChooser.decode(try await client.next(body: NextChooser.encode(request)))
            tasteEvents = response.profile.events
            if response.profile.events == 0 {
                log.info("Infinity is still learning what this listener likes: no finished plays yet")
            }
            let chosen = response.candidates.filter { !known.contains($0.id) }
            for candidate in chosen { reasons[candidate.id] = candidate.factors }
            // Items come back in the order asked for, and the order asked for
            // is the server's.
            return try await client.items(ids: chosen.map(\.id))
        } catch MeleteError.notFound {
            sidecarChooses = false
            log.info("This server has no /aoide/next; Infinity rests for the session")
            return nil
        } catch {
            log.warning("The server couldn't choose what plays next: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - PlaybackReporter

    /// Every track change is a chance to look ahead. Reporting is where the app
    /// learns about them wherever they happen — the phone, the car, or the lock
    /// screen — so it is the one place a top-up cannot be missed.
    func playbackDidStart(_ track: Track) async {
        await topUpIfNeeded()
        // What is coming, fetched for the decks before it is needed — after the
        // top-up, so the records it just chose are the ones fetched.
        let queue = PlaybackEngine.shared.queue
        let ahead = [queue.current].compactMap { $0 } + queue.upNext
        TransientTracks.shared.prepare(ahead.map(\.track))
        BeatGridSync.shared.prefetch(ids: ahead.prefix(TransientTracks.capacity).map(\.track.id))
        ArrangementSync.shared.prefetch(ids: ahead.prefix(TransientTracks.capacity).map(\.track.id))
    }

    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async {}
    func playbackDidStop(_ track: Track, position: Duration) async {}
}
