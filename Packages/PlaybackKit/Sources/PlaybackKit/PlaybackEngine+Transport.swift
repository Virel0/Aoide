#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Transport

extension PlaybackEngine {
    /// Pauses if playing; otherwise plays.
    public func togglePlayPause() {
        switch state {
        case .playing: pause()
        case .paused, .idle, .buffering, .failed: resume()
        }
    }

    /// Plays the current track, reloading it first if what is loaded is unusable.
    public func resume() {
        guard queue.current != nil else { return }

        // A phone call deactivates this app's audio session, and nothing hands it
        // back on its own: without this, every play after a call was silence, and
        // the only cure was relaunching. Cheap and idempotent, so it costs a
        // no-op on the ordinary path.
        activateSession()

        if isUsingDecks {
            resumeOnDecks()
            return
        }

        // Rebuild whenever what's loaded is unusable, not only when it's missing.
        // AVQueuePlayer does not advance past a failed item, so without this a
        // retry called `play()` on a dead item and the UI claimed to be playing
        // with silence coming out — permanently.
        if loadedItemIsUnusable {
            // The server never saw a Stopped for the track that died.
            stopReportingCurrent()
            beginCurrentTrack(autoplay: true)
            return
        }

        intendsToPlay = true
        player.play()
        if blend?.isRunning == true { spareDeck.play() }
        state = .playing
        updateNowPlayingInfo()

        // A restored queue has reported nothing yet, so the listen opens here
        // instead — otherwise the one track somebody comes back to would be the
        // one track the history never sees.
        openListenIfNeeded()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
    }

    /// Whether the player has nothing it can play: no item, a dead item, or a
    /// state that already gave up.
    private var loadedItemIsUnusable: Bool {
        if case .failed = state { return true }
        return player.currentItem == nil || player.currentItem?.status == .failed
    }

    private func resumeOnDecks() {
        intendsToPlay = true
        djSession?.resume(at: djClock())
        // A hand-over booked before the pause was abandoned by it; the
        // next tick books again from where the record now is.
        if djSession?.hasScheduledMix == false {
            djScheduledEntryId = nil
            booked = nil
        }
        state = .playing
        updateNowPlayingInfo()
        openListenIfNeeded()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: false) }
    }

    /// Opens the listen for the current track unless it is already open.
    private func openListenIfNeeded() {
        if let track = queue.currentTrack, reportedStartFor != track.id {
            openListen(for: track)
        }
    }

    /// Pauses playback, including a blend or a mix in flight.
    public func pause() {
        intendsToPlay = false
        if isUsingDecks {
            djSession?.pause(at: djClock())
            state = .paused
            updateNowPlayingInfo()
            report { await $0.playbackDidProgress($1, position: $2, isPaused: true) }
            return
        }
        player.pause()
        // A blend in flight is two decks playing; pausing one of them would leave
        // half a crossfade audible.
        if blend?.isRunning == true { spareDeck.pause() }
        state = .paused
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: true) }
    }

    /// Skips to the next track, or stops if the queue has run out.
    public func next() {
        // If the player auto-advanced while this tap was in flight, adopt where it
        // actually is before skipping — otherwise the queue skips from a stale
        // position and the listener loses a whole track. Reconciling reports the
        // outgoing track itself, so don't report it twice.
        if !reconcileWithPlayer() {
            stopReportingCurrent()
        }
        switch queue.skipToNext() {
        case .moved, .repeatCurrent:
            beginCurrentTrack(autoplay: true)
        case .ended:
            stopReportingCurrent()
            finishPlayback()
        }
    }

    /// Previous restarts the current track unless we're still near its beginning.
    public func previous() {
        // Reconcile first. Right after a boundary `elapsed` still holds the
        // *outgoing* track's position, so testing the restart rule before adopting
        // the new track would restart the one that just started instead of going
        // back to the one that just finished.
        let advanced = reconcileWithPlayer()

        if !advanced, elapsed > restartThreshold {
            seek(to: .zero)
            return
        }

        // Report the outgoing track BEFORE the queue moves — `stopReportingCurrent`
        // reads `queue.currentTrack`, so afterwards it would attribute the stop to
        // the track being moved to. But only report at all if we actually leave:
        // at the head of the queue `skipToPrevious` returns `.ended` and the track
        // carries on playing, and closing its server session then leaves the rest
        // of the play unrecorded.
        var probe = queue
        let willMove = probe.skipToPrevious() != .ended

        if !advanced, willMove { stopReportingCurrent() }

        switch queue.skipToPrevious() {
        case .moved, .repeatCurrent:
            beginCurrentTrack(autoplay: true)
        case .ended:
            seek(to: .zero)
        }
    }

    /// Plays a queue entry straight away — tapping a row in Up Next.
    public func jump(to entryId: UUID) {
        guard queue.current?.id != entryId else { return }
        // Report the outgoing track before moving, or the stop is attributed to
        // the track the user just jumped to.
        stopReportingCurrent()
        guard queue.jump(to: entryId) else { return }
        beginCurrentTrack(autoplay: true)
    }

    /// How far off the requested position the player may land.
    ///
    /// Zero forces a sample-accurate seek: the player must fetch and decode from
    /// the sync point *preceding* the target before anything resumes. Over a
    /// network stream that stalls for as long as it takes, and
    /// `addPeriodicTimeObserver` does not fire while it does — so the scrubber
    /// freezes at wherever it was and the audio goes quiet, which reads as the app
    /// hanging. A quarter-second is inaudible when a finger just dragged across a
    /// four-minute song, and it lets the player land on a sync point it already
    /// holds.
    private static let seekTolerance = CMTime(seconds: 0.25, preferredTimescale: 600)

    /// The player's SharePlay coordinator.
    ///
    /// Exposed so the app can attach a `GroupSession` to it without PlaybackKit
    /// importing GroupActivities — this package stays about playing audio, and the
    /// question of who else is listening belongs a layer up.
    public var playbackCoordinator: AVPlayerPlaybackCoordinator { player.playbackCoordinator }

    /// Moves the playhead, clamped to the track.
    public func seek(to position: Duration) {
        // The fade was scheduled against the clock the listener has just moved.
        cancelBlend()
        let clamped = max(.zero, min(position, duration ?? position))

        if isUsingDecks {
            // A mix booked against where the record *was* is abandoned by the
            // session; the tick will book another if the new position still has
            // one ahead of it.
            djScheduledEntryId = nil
            try? djSession?.seek(to: clamped.seconds, at: djClock())
            elapsed = clamped
            updateNowPlayingInfo()
            report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
            return
        }

        player.seek(
            to: clamped.cmTime,
            toleranceBefore: Self.seekTolerance,
            toleranceAfter: Self.seekTolerance
        )
        elapsed = clamped
        updateNowPlayingInfo()
        report { await $0.playbackDidProgress($1, position: $2, isPaused: !self.state.isPlaying) }
    }

    /// Turns shuffle on or off; the current track keeps playing.
    public func setShuffled(_ shuffled: Bool) {
        queue.setShuffled(shuffled)
        syncPlayer()
    }

    /// Takes an entry out of the queue, moving on if it was the one playing.
    public func remove(entryId: UUID) {
        let wasCurrent = queue.current?.id == entryId
        queue.remove(entryId: entryId)
        if wasCurrent {
            if queue.current == nil {
                finishPlayback()
            } else {
                beginCurrentTrack(autoplay: state.isPlaying)
            }
        } else {
            syncPlayer()
        }
    }

    /// Reorders Up Next by drag.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        syncPlayer()
    }
}

#endif
