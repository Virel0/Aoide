#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Boundary and the player's clock

extension PlaybackEngine {
    func observeCurrentItem() {
        // Fires exactly once per transition, including the automatic ones we don't
        // initiate. `AVPlayerItem` isn't Sendable, so only its identity crosses.
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let key = player.currentItem.map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                self?.handleCurrentItemChanged(key)
            }
        }
    }

    /// The car and the lock screen do not poll us — they extrapolate the position
    /// from the last value we reported multiplied by the playback rate. Report a
    /// rate of zero and their clock simply stops, which is what left CarPlay frozen
    /// at 0:00 over a track that was audibly playing.
    ///
    /// `AVPlayer.rate` is the only honest source for that, and it settles some time
    /// after `play()` — so it has to be observed rather than sampled.
    func observeRate() {
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate = player.rate
            Task { @MainActor [weak self] in
                self?.handleRateChanged(rate)
            }
        }
    }

    private func handleRateChanged(_ rate: Float) {
        // Reconcile: audio moving means playing, whatever we previously believed.
        if rate > 0, state != .playing {
            state = .playing
        } else if rate == 0, state == .playing, !intendsToPlay {
            state = .paused
        }
        updateNowPlayingInfo()
    }

    private func handleCurrentItemChanged(_ key: ObjectIdentifier?) {
        // While the decks have the record, the player is either being faded out
        // of a hand-over or already empty. Either way its boundaries are not the
        // queue's, and acting on one would tear the decks down mid-record.
        guard !isUsingDecks else { return }

        guard let key, let entryId = entryForItem[key] else {
            handlePlayerRanDry()
            return
        }

        // Ignore the echo from our own rebuild — that path already did this work.
        guard key != enqueued.first else { return }

        followAutomaticAdvance(to: key, entryId: entryId)
    }

    /// The queue drained on its own. Report the last track's stop before
    /// tearing down — otherwise the final track of every queue never counts
    /// as played on the server.
    private func handlePlayerRanDry() {
        guard player.currentItem == nil, !enqueued.isEmpty else { return }
        // A deck that runs dry mid-blend has not reached the end of the
        // queue; it has reached the end of its track, and the next one is
        // already playing on the other deck.
        if completeBlend() { return }
        stopReportingCurrent()
        finishPlayback()
    }

    /// The player moved on to the next item by itself; the queue follows it.
    private func followAutomaticAdvance(to key: ObjectIdentifier, entryId: UUID) {
        // Report the *outgoing* track before the queue moves. Reading
        // queue.currentTrack after the move would attribute the scrobble to the
        // track that just started.
        stopReportingCurrent()

        _ = queue.jump(to: entryId)

        // Release everything the player retired on its way here, or the observation
        // maps grow for the whole session.
        if let index = enqueued.firstIndex(of: key) {
            for retired in enqueued.prefix(index) { release(key: retired) }
            enqueued.removeFirst(index)
        }

        applyLoudness(for: queue.currentTrack)

        elapsed = .zero
        lastReportedSecond = -1
        // Prefer the real decoded length. A look-ahead item reaches .readyToPlay
        // while it is still queued, so its duration was cached there rather than
        // arriving now.
        exitAt = nil
        duration = assetDurations[key]
            ?? player.currentItem?.duration.validDuration
            ?? queue.currentTrack?.duration
        state = player.rate > 0 ? .playing : .paused

        // Synchronous, so a car head unit never shows the previous title over the
        // new audio.
        updateNowPlayingInfo()

        if let track = queue.currentTrack {
            openListen(for: track)
        }

        // Top the window back up behind the new current track.
        syncPlayer()
    }

    func observePlayerTime() {
        // Twice a second: fine enough for a smooth scrubber, coarse enough not to
        // spin the CPU while the screen is off. It also drives the ~10s server
        // report below, so the interval isn't free to change.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.handleTimeUpdate(time)
            }
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        // `validDuration` rejects the negative and indefinite times that appear
        // across a transition, which is why no generation counter is needed here.
        guard let seconds = time.validDuration else { return }
        elapsed = seconds

        considerBlend()
        considerDeckTakeover()

        // No per-tick push of the position: with an honest rate reported, the
        // system extrapolates between our updates on its own, and rewriting the
        // whole dictionary twice a second is waste. Seeks and track changes
        // already refresh it explicitly.

        reportProgressIfDue(atWholeSecond: Int(time.seconds))
    }
}

#endif
