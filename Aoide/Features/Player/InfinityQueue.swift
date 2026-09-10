import CurationKit
import JellyfinKit
import PlaybackKit
import SwiftUI
import os

/// Infinity: keeps the music going when the queue runs out.
///
/// Off by default — a queue that ends is not a fault, and a player that quietly
/// plays on for an hour after the album finished is one nobody asked for.
///
/// What it finds comes from the server's own Instant Mix, seeded by whatever is
/// playing, and is then ranked against what this listener has actually been
/// listening to. See ``rank(_:seed:)``.
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

    /// How many the station is asked for to choose those from. Wide enough that
    /// the ranking has something to reject, narrow enough to stay one request.
    static let pool = 100

    /// How far back the taste profile reads. Taste moves; a year of listening
    /// describes somebody who no longer exists.
    static let windowDays = 90.0

    private let log = Logger(subsystem: "com.example.aoide", category: "infinity")

    private(set) var isOn: Bool = UserDefaults.standard.bool(forKey: InfinityQueue.key)

    /// One fetch at a time. Track changes and the toggle can both ask at once,
    /// and two stations arriving would double every top-up.
    private var isFetching = false

    private init() {}

    func setOn(_ on: Bool) {
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.key)
        if on { Task { await topUpIfNeeded() } }
    }

    /// Adds more songs if the queue is nearly out of them.
    func topUpIfNeeded() async {
        guard isOn, !isFetching else { return }

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
        do {
            // The station is the pool, not the answer: Jellyfin picks what is
            // *like* this song, and what follows is picked from that by what this
            // listener actually finishes.
            let pool = try await client.instantMix(seededBy: seed.id, limit: Self.pool)
            let allowed = await TasteStore.shared.withoutNotInterested(pool)
                .filter { !known.contains($0.id) }
            guard !allowed.isEmpty else {
                log.info("Infinity found nothing new to add after \(seed.title, privacy: .public)")
                return
            }

            let chosen = rank(allowed)
            let tracks = JellyfinPlaybackBridge.playableTracks(from: chosen, client: client).tracks
            guard !tracks.isEmpty else { return }
            // Left attributed to whatever the queue already was rather than dressed
            // up as a choice: nobody picked these, and the history should not say
            // they did.
            engine.extendQueue(tracks)
            log.info("Infinity added \(tracks.count) songs after \(seed.title, privacy: .public)")
        } catch {
            // Nothing to tell anyone about. The queue simply ends, which is what
            // it would have done anyway.
            log.warning("Infinity couldn't reach the server: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts the station's suggestions in the order this listener is likeliest to
    /// want them, and takes the best handful.
    ///
    /// The judgement is [`TasteRanking`](../../../Packages/CurationKit/Sources/CurationKit/TasteProfile.swift)'s,
    /// working off the local history: which genres and artists get finished, what
    /// each candidate's own finish rate is, and what has been heard lately. If
    /// there is no history to read — a new install, or a database that failed to
    /// open — the station's own order stands, which is what this did before.
    private func rank(_ items: [JellyfinItem]) -> [JellyfinItem] {
        guard let store = CurationDatabase.shared else { return Array(items.prefix(Self.batch)) }

        let candidates = items.map {
            // The same artist string the history is keyed on — the bridge writes
            // exactly this into `Track.artist`, and the cache follows it.
            TasteCandidate(
                id: $0.id,
                artist: $0.albumArtist ?? $0.artists.first ?? "Unknown Artist",
                genres: $0.genres
            )
        }
        let since = Date().addingTimeInterval(-Self.windowDays * 24 * 60 * 60).millis
        guard let profile = try? store.tasteProfile(since: since),
              !profile.isEmpty
        else { return Array(items.prefix(Self.batch)) }

        let finish = (try? store.finishCounts(jellyfinIds: candidates.map(\.id))) ?? [:]
        let ranked = TasteRanking.rank(candidates, in: profile, finish: finish, limit: Self.batch)

        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byId[$0.id] }
    }

    // MARK: - PlaybackReporter

    /// Every track change is a chance to look ahead. Reporting is where the app
    /// learns about them wherever they happen — the phone, the car, or the lock
    /// screen — so it is the one place a top-up cannot be missed.
    func playbackDidStart(_ track: Track) async {
        await topUpIfNeeded()
    }

    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async {}
    func playbackDidStop(_ track: Track, position: Duration) async {}
}
