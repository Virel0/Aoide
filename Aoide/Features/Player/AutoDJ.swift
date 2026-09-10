import JellyfinKit
import PlaybackKit
import SwiftUI
import os

/// Keeps the music going when the queue runs out.
///
/// The other half of the DJ: [AutoMix](../../../docs/automix.md) decides how one
/// song becomes the next, and this decides that there *is* a next one. Off by
/// default — a queue that ends is not a fault, and a player that quietly plays on
/// for an hour after the album finished is one nobody asked for.
///
/// What it finds comes from the server's own Instant Mix, seeded by whatever is
/// playing. That is the same station this app already offers by hand, so nothing
/// new decides what a song is like: the library that knows the music does.
@MainActor
@Observable
final class AutoDJ: PlaybackReporter {
    static let shared = AutoDJ()

    static let key = "aoide.autoDJ"

    /// Top up when fewer than this many songs are left in front of the listener.
    /// Far enough ahead that Up Next is never a dead end to look at, close enough
    /// that a station's worth of songs is not fetched for a queue somebody was
    /// about to clear.
    static let minimumAhead = 3

    /// How many to add each time. A handful of songs, not a shift's worth: the
    /// seed moves on as the queue plays, so asking again later gives something
    /// that follows what is playing *then*.
    static let batch = 20

    private let log = Logger(subsystem: "com.example.aoide", category: "autodj")

    private(set) var isOn: Bool = UserDefaults.standard.bool(forKey: AutoDJ.key)

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
            let mix = try await client.instantMix(seededBy: seed.id, limit: Self.batch * 4)
            let wanted = await TasteStore.shared.withoutNotInterested(mix)
                .filter { !known.contains($0.id) }
                .prefix(Self.batch)
            let tracks = JellyfinPlaybackBridge.playableTracks(from: Array(wanted), client: client).tracks
            guard !tracks.isEmpty else {
                log.info("Auto DJ found nothing new to add after \(seed.title, privacy: .public)")
                return
            }
            // Left as whatever the current queue was attributed to rather than
            // dressed up as a choice: nobody picked these, and the history should
            // not say they did.
            engine.extendQueue(tracks)
            log.info("Auto DJ added \(tracks.count) songs after \(seed.title, privacy: .public)")
        } catch {
            // Nothing to tell anyone about. The queue simply ends, which is what
            // it would have done anyway.
            log.warning("Auto DJ couldn't reach the server: \(error.localizedDescription, privacy: .public)")
        }
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
