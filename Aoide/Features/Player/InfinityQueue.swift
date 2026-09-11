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

            // With a set to program, the pool has to be readable before it can
            // be ranked: the grids and arrangements are asked for and given a
            // moment to arrive. A record still unread ranks by taste alone.
            if AutoDJPreference.isOn {
                BeatGridSync.shared.prefetch(ids: allowed.map(\.id))
                ArrangementSync.shared.prefetch(ids: allowed.map(\.id))
                try? await Task.sleep(for: .seconds(2))
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
        let ranked = TasteRanking.rank(
            candidates,
            in: profile,
            finish: finish,
            compatibility: compatibility(of: items),
            limit: Self.batch
        )

        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ranked.compactMap { byId[$0.id] }
    }

    /// How well each candidate could follow the record playing, when a set is
    /// being programmed — the same score the mix itself would get, asked ahead
    /// of time. Nothing when Auto DJ is off: without it the question does not
    /// arise, and the queue is ordered by taste alone.
    ///
    /// A pair that would be refused scores a little rather than nothing: it
    /// can still crossfade, and a room would rather hear a good record faded in
    /// than a mediocre one mixed.
    private func compatibility(of items: [JellyfinItem]) -> [String: Double] {
        guard AutoDJPreference.isOn,
              let current = PlaybackEngine.shared.queue.currentTrack,
              let grid = BeatGridSync.shared.grid(for: current.id),
              let arrangement = ArrangementSync.shared.arrangement(for: current.id)
        else { return [:] }

        var scores: [String: Double] = [:]
        for item in items {
            guard let candidateGrid = BeatGridSync.shared.grid(for: item.id),
                  let candidateArrangement = ArrangementSync.shared.arrangement(for: item.id)
            else { continue }
            let plan = DJPlanner.plan(
                outgoing: grid, incoming: candidateGrid,
                outgoingArrangement: arrangement, incomingArrangement: candidateArrangement
            )
            scores[item.id] = plan?.score.total ?? Self.crossfadeOnly
        }
        return scores
    }

    /// What a record that can only be crossfaded into is worth, against one
    /// that can be mixed.
    static let crossfadeOnly = 0.15

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
