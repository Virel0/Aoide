#if os(iOS)

import Foundation

// MARK: - Loading

extension PlaybackEngine {
    /// Replaces the queue and starts playing.
    public func play(_ tracks: [Track], startingAt index: Int = 0, shuffled: Bool = false) {
        guard !tracks.isEmpty else { return }
        stopReportingCurrent()
        // A fresh queue gets a fresh chance for anything that failed before — the
        // failure may well have been a passing network problem.
        forgetLoadFailures()
        queue.load(tracks, startingAt: index, shuffled: shuffled)
        beginCurrentTrack(autoplay: true)
    }

    /// Puts tracks at the front of the hand-picked lane, ahead of anything
    /// queued earlier, or starts them if nothing is queued.
    public func playNext(_ tracks: [Track]) {
        // Into an empty queue this becomes a load, so it has to actually start —
        // otherwise the track sits loaded and silent and is never reported.
        let wasEmpty = queue.isEmpty
        queue.playNext(tracks)
        if wasEmpty {
            beginCurrentTrack(autoplay: true)
        } else {
            syncPlayer()
        }
    }

    /// Adds tracks after everything queued by hand, or starts them if nothing
    /// is queued.
    public func addToQueue(_ tracks: [Track]) {
        let wasEmpty = queue.isEmpty
        queue.append(tracks)
        if wasEmpty {
            beginCurrentTrack(autoplay: true)
        } else {
            syncPlayer()
        }
    }

    /// Adds songs the app went looking for when the queue was running out.
    ///
    /// Separate from ``addToQueue(_:)`` because these were not chosen: they go
    /// behind everything rather than into the hand-picked lane, and they never
    /// start playback on their own — an empty queue that fills itself would be a
    /// player that started playing while nobody was there.
    public func extendQueue(_ tracks: [Track]) {
        guard !queue.isEmpty else { return }
        queue.extend(tracks)
        syncPlayer()
    }

    /// Clears what comes next; the current track plays on.
    public func clearUpNext() {
        queue.clearUpNext()
        syncPlayer()
    }

    /// Empties the queue and stops playback.
    public func clearQueue() {
        stopReportingCurrent()
        forgetLoadFailures()
        queue.clear()
        finishPlayback()
    }
}

#endif
