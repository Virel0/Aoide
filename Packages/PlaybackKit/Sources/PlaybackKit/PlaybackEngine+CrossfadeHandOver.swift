#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Crossfade: performing the hand-over

extension PlaybackEngine {
    /// Lets the incoming track be heard, and starts taking the outgoing one down.
    ///
    /// The fade-out is driven by the outgoing deck's own clock rather than a
    /// timer: a clock that only advances when audio does cannot drift away from
    /// the music, and it keeps running with the screen off, which a display link
    /// does not. Twenty steps a second puts each step a small fraction of a
    /// decibel from the last, which is well under what anyone can hear.
    func startBlend() {
        guard let current = blend, !current.isRunning, current.isFadeReady else { return }
        guard let fadeEnd = outgoingEnd(), fadeEnd.isFinite else { return }

        blend?.isRunning = true
        blend?.outgoingVolume = player.volume

        let base = player.volume
        let overlap = current.overlap.seconds
        let deck = player
        fadeObserver = deck.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let progress = (time.seconds - (fadeEnd - overlap)) / overlap
            deck.volume = base * Float(MixCurve.outgoing(progress: progress))
            self?.mixState = .mixing(.crossfade(seconds: overlap), progress: max(0, min(1, progress)))
        }

        spareDeck.play()
    }

    /// Where the track playing now stops, in its own timeline.
    private func outgoingEnd() -> Double? {
        guard let track = queue.currentTrack else { return nil }
        if let sound = track.sound ?? soundResolver?(track) { return sound.soundEnd.seconds }
        return duration?.seconds
    }

    /// Takes the fade-out off whichever deck was carrying it and puts its fader
    /// back where levelling had it.
    private func endFadeOut(restoringVolumeOn deck: AVQueuePlayer) {
        guard let fadeObserver else { return }
        deck.removeTimeObserver(fadeObserver)
        self.fadeObserver = nil
        deck.volume = blend?.outgoingVolume ?? 1
    }

    /// The outgoing track has finished and its deck is empty. Hand over.
    ///
    /// Returns whether it did, so the ordinary "the queue ran out" path can carry
    /// on when there was no blend in flight.
    func completeBlend() -> Bool {
        guard let running = blend, running.isRunning, let key = running.itemKey else { return false }

        stopReportingCurrent()

        // Retire the deck that just ran dry before it becomes the spare one.
        endFadeOut(restoringVolumeOn: player)
        player.pause()
        player.removeAllItems()
        for retired in enqueued { release(key: retired) }
        enqueued = [key]

        swapDecks()
        _ = queue.jump(to: running.entryId)

        blend = nil
        mixState = .off
        lastReportedSecond = -1
        elapsed = player.currentTime().validDuration ?? .zero
        exitAt = nil
        duration = assetDurations[key]
            ?? player.currentItem?.duration.validDuration
            ?? running.track.duration
        state = player.rate > 0 ? .playing : .paused
        updateNowPlayingInfo()

        // Reported here rather than when the fade began: the listen is opened
        // once, at the moment this track becomes the one playing, so a blend does
        // not put two open plays in the history at the same time.
        openListen(for: running.track)

        syncPlayer()
        return true
    }

    /// Moves the observations that watch "the player" onto the other deck.
    ///
    /// They are re-installed rather than kept on both, so nothing in this engine
    /// has to ask which deck a callback came from.
    private func swapDecks() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        currentItemObservation?.invalidate()
        currentItemObservation = nil
        rateObservation?.invalidate()
        rateObservation = nil

        playingDeckB.toggle()

        observeCurrentItem()
        observeRate()
        observePlayerTime()
    }

    /// Abandons whatever was prepared. Safe to call when nothing is.
    ///
    /// - Parameter resync: whether to put the incoming track back into this
    ///   deck's window. False only where the caller is about to rebuild it
    ///   anyway, or is tearing everything down — `syncPlayer` can decide the
    ///   queue has run out, and calling it from inside that decision would go
    ///   round in circles.
    func cancelBlend(resync: Bool = true) {
        guard let cancelled = blend else { return }
        endFadeOut(restoringVolumeOn: player)
        blend = nil
        if !isUsingDecks { mixState = .off }
        spareDeck.pause()
        spareDeck.removeAllItems()
        if let key = cancelled.itemKey { release(key: key) }
        if resync { syncPlayer() }
    }
}

#endif
