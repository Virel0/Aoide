import CurationKit
import Foundation
import PlaybackKit
import UIKit
import os

/// Writes what was actually listened to into the local curation store.
///
/// Hangs off the same `PlaybackReporter` calls that already tell Jellyfin about a play,
/// and is strictly *additional* to them — Jellyfin still counts what Jellyfin counts.
/// The reason for a second set of books is that the server's count increments the moment
/// playback starts, so skipping through an album marks every track as played. This one
/// can tell a four-second skip from a whole song, which is the fact every recap, smart
/// playlist and weighted shuffle is built out of.
///
/// An actor rather than a `@MainActor` type, deliberately. SQLite writes block the thread
/// they run on, and the main actor is where the UI, the queue and the now-playing
/// dictionary live — a write stalling it is a dropped frame on the phone, or a car head
/// unit that freezes before it redraws. The only thing that genuinely has to happen on the
/// main actor is *reading* the engine, and that is one hop at the top of each report.
actor CurationRecorder: PlaybackReporter {
    private let log = Logger(subsystem: "com.example.aoide", category: "curation")

    /// A play that has begun and not yet been closed out. At most one, because at most
    /// one track is playing.
    private struct OpenPlay {
        let event: PlayEvent
        let trackId: String
        /// The real decoded length where the player has it, which can differ from the
        /// server's metadata — and the play/skip line is drawn against it.
        var durationMs: Int?
        /// The furthest the listener was last seen to reach, for closing this play if no
        /// stop report ever arrives to say where they got to.
        var msPlayed: Int
        /// Set when the start that opened this play had to close a previous play of the
        /// *same track*, which means a stop report belonging to that previous play is
        /// still in flight behind us. See `playbackDidStop`.
        var owesSupersededStop: Bool
    }

    private var openPlay: OpenPlay?

    // MARK: - Reports

    func playbackDidStart(_ track: Track) async {
        guard let snapshot = await Snapshot.take(for: track) else { return }

        // Close anything still open before opening the next one. In the ordinary run of
        // things there is nothing to close — the engine reports a stop before every start
        // — but two paths reach here without one: removing the entry that is currently
        // playing, and a stop report losing the race with the start behind it, since each
        // report is dispatched as its own task. Either way, a play closed on the last
        // position we saw is worth more than one left open forever.
        let closedSameTrack = closeOpenPlay(at: snapshot.now, store: snapshot.store, of: track.id)

        let row = snapshot.cacheRow
        do {
            // `writeLocal`, not `record`: the track cache is this device's own copy of
            // what Jellyfin already knows, rebuilt from its own connection. Syncing it
            // would dominate the payload and buy nothing.
            try snapshot.store.writeLocal { db in try row.save(db) }
        } catch {
            // Not fatal to the play. A history row with no cached track still counts —
            // that is what `unattributedPlays` exists to admit to — so carry on and
            // record it.
            log.error("Couldn't cache \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        // "Don't count this" means exactly that: no event is opened, so nothing is
        // there to count later. History already recorded stays.
        if (try? snapshot.store.flags(for: track.id))?.dontCount == true {
            log.info("Not counting a play of \(track.title, privacy: .public): flagged")
            return
        }

        do {
            let event = try snapshot.store.beginPlay(
                jellyfinId: track.id,
                contentKey: row.contentKey,
                source: snapshot.source,
                at: snapshot.now
            )
            openPlay = OpenPlay(
                event: event,
                trackId: track.id,
                durationMs: snapshot.durationMs,
                msPlayed: 0,
                owesSupersededStop: closedSameTrack
            )
        } catch {
            log.error("Couldn't open a play for \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        save(snapshot.queue, to: snapshot.store)
    }

    func playbackDidProgress(_ track: Track, position: Duration, isPaused: Bool) async {
        guard let snapshot = await Snapshot.take(for: track) else { return }

        // Mutated through a local copy and written back, rather than in place. Swift
        // enforces exclusive access to a property for the whole of an assignment, so
        // `openPlay?.msPlayed = max(openPlay?.msPlayed ?? 0, …)` reads `openPlay` while
        // its own modify access is still open and traps with "Simultaneous accesses …
        // modification requires exclusive access". Deterministic, not a race: it fired
        // on the first progress report of every track, so every song crashed.
        if var play = openPlay, play.trackId == track.id {
            // A high-water mark, not the latest reading: seeking backwards must not undo
            // what was already listened to.
            play.msPlayed = max(play.msPlayed, position.milliseconds)
            // The asset's real duration only becomes known once it decodes, which is
            // after the play was opened. Adopt it whenever it turns up.
            if let durationMs = snapshot.durationMs { play.durationMs = durationMs }
            openPlay = play
        }

        save(snapshot.queue, to: snapshot.store)
    }

    func playbackDidStop(_ track: Track, position: Duration) async {
        guard let store = await Self.store() else { return }
        // Only the play this stop is actually about. A stop for a track we are no longer
        // holding open has already been accounted for by the start that overtook it, and
        // applying it to whatever is open now would file one listener's position against
        // another song.
        guard let play = openPlay, play.trackId == track.id else { return }

        // Matching on the track id alone is not enough when the track repeats. The engine
        // emits a same-track stop/start pair on every repeat-one cycle, on a jump to a
        // duplicate of the song already playing, and on `play()` of what is already
        // playing — and if the start wins that race it has already closed the outgoing
        // play and opened a fresh one under the same id. Applying the overtaken stop here
        // would close the *new* play at the old one's final position: a full-length,
        // `completed` listen written before a millisecond of it was heard, inflating every
        // play count, `totalMsPlayed` and Most Played list downstream.
        //
        // The two conditions together are what make this safe. `owesSupersededStop` says a
        // stop for this track is outstanding, and `msPlayed == 0` says nothing has been
        // seen of this play yet — a boundary's first progress report carries position zero,
        // so a real listen moves off zero and reclaims its own stop. The play the stale
        // report belonged to was already closed at its high-water mark, which is what
        // `PlayClassifier.completionToleranceMs` exists to accept, so nothing is lost by
        // dropping it.
        if play.owesSupersededStop, play.msPlayed == 0 {
            openPlay?.owesSupersededStop = false
            return
        }

        openPlay = nil
        // Against the high-water mark, not the position alone. Somebody who hears three
        // minutes of a track, drags back to the second verse and then skips has listened
        // to three minutes — taking the final position literally would file that as a
        // rejection of a song they sat through, which is the exact dishonesty this table
        // exists to correct.
        close(play, msPlayed: max(play.msPlayed, position.milliseconds), at: Date().millis, store: store)
    }

    // MARK: - Sign-out

    /// Empties this device's stored queue.
    ///
    /// An empty row rather than a deleted one, which is `clearQueue`'s whole point: a
    /// missing row is indistinguishable from one never seen, so the other devices would
    /// go on offering this one's stale queue forever.
    func clearSavedQueue() async {
        guard let store = await Self.store() else { return }
        do {
            _ = try store.clearQueue()
        } catch {
            log.error("Couldn't clear the saved queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Writing

    /// Closes whatever is open, and reports whether it was the same track as `trackId` —
    /// which tells the caller a stop report for it is still owed. See `playbackDidStop`.
    private func closeOpenPlay(at now: Millis, store: CurationStore, of trackId: String) -> Bool {
        guard let play = openPlay else { return false }
        openPlay = nil
        close(play, msPlayed: play.msPlayed, at: now, store: store)
        return play.trackId == trackId
    }

    /// Amends the event `beginPlay` wrote with how the play went.
    ///
    /// `completed` is left to the classifier rather than asserted here. The engine reports
    /// its last observed position, which at a natural boundary sits a fraction of a second
    /// short of the duration — inside `PlayClassifier.completionToleranceMs`, which exists
    /// for exactly that.
    private func close(_ play: OpenPlay, msPlayed: Int, at now: Millis, store: CurationStore) {
        do {
            let event = try store.finishPlay(
                play.event,
                msPlayed: msPlayed,
                trackDurationMs: play.durationMs,
                endedAt: now
            )
            // The only outward sign this path ran at all. Everything it writes goes into
            // a database with no screen in front of it yet, so without a line here the
            // difference between "recording" and "silently doing nothing" is invisible
            // until the first recap is built months from now.
            log.debug("""
                Play closed: \(play.trackId, privacy: .public) \
                \(msPlayed, privacy: .public)/\(play.durationMs ?? -1, privacy: .public) ms \
                completed=\(event.completed, privacy: .public) skipped=\(event.skipped, privacy: .public) \
                source=\(event.source ?? "—", privacy: .public)
                """)
        } catch {
            // The event stays on disk with no `endedAt`, which reads as "started, outcome
            // unknown" and counts as neither a play nor a skip. Losing a play count is not
            // worth a word to the listener.
            log.error("Couldn't close a play: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persists the queue, if anything about it moved.
    ///
    /// No timer: `saveQueueIfChanged` is cheap to ask and does nothing unless the list,
    /// the index or more than five seconds of elapsed time changed, so asking on the
    /// reports the engine already sends — a track change, and the throttled progress tick
    /// roughly every ten seconds — costs a comparison and usually no write at all. The
    /// price is that a queue edit made while paused isn't stored until the next tick.
    private func save(_ queue: Snapshot.Queue, to store: CurationStore) {
        do {
            _ = try store.saveQueueIfChanged(
                deviceName: queue.deviceName,
                trackIds: queue.trackIds,
                position: queue.position,
                elapsedMs: queue.elapsedMs
            )
        } catch {
            log.error("Couldn't save the queue: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - What the main actor knows

    /// Everything behind a report that only the main actor can see, read in one hop.
    ///
    /// One hop rather than several because the queue moves underneath us: reading the
    /// source, then the duration, then the track list as three separate awaits would let a
    /// track boundary land between them and produce a snapshot describing no moment that
    /// ever existed.
    private struct Snapshot: Sendable {
        struct Queue: Sendable {
            let deviceName: String
            let trackIds: [String]
            let position: Int
            let elapsedMs: Int
        }

        let store: CurationStore
        let source: PlaySource
        let cacheRow: TrackRef
        let durationMs: Int?
        let queue: Queue
        let now: Millis

        @MainActor
        static func take(for track: Track) -> Snapshot? {
            // Never force-unwrapped, and never an error worth reporting: the store is
            // absent when it failed to open, and the whole point of leaving it optional is
            // that music still plays without it.
            guard let store = CurationDatabase.shared else { return nil }

            let engine = PlaybackEngine.shared
            let now = Date().millis
            let isCurrent = engine.currentTrack?.id == track.id

            return Snapshot(
                store: store,
                source: PlaybackContext.source(of: track),
                cacheRow: PlaybackContext.cacheRow(for: track, at: now),
                // The engine's duration is the decoded one, and it is only about this
                // track while this track is the one playing.
                // With a trailing silence trimmed, the sound's end is the end the
                // listener reached; measuring completion against the file's full
                // length would call every such play unfinished.
                durationMs: (isCurrent ? engine.duration : track.duration)
                    .map { full in track.sound.map { min(full, $0.soundEnd) } ?? full }
                    .map { Int(($0.seconds * 1000).rounded()) },
                queue: Queue(
                    // `UIDevice.current.name` is what the resume prompt on another device
                    // will read out, so it is stored rather than derived at read time.
                    deviceName: UIDevice.current.name,
                    trackIds: engine.queue.entries.map(\.track.id),
                    position: engine.queue.position ?? 0,
                    elapsedMs: engine.elapsed.milliseconds
                ),
                now: now
            )
        }
    }

    @MainActor
    private static func store() -> CurationStore? { CurationDatabase.shared }
}

private extension Duration {
    /// Milliseconds, floored at zero. A position read across a track boundary can briefly
    /// be negative, and a negative figure here would poison every `SUM(msPlayed)` after it
    /// with nothing left to notice it by.
    var milliseconds: Int { max(0, Int((seconds * 1000).rounded())) }
}
