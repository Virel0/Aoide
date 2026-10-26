#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Starting a track

extension PlaybackEngine {
    /// Starts whatever the queue now says is current, from the beginning.
    func beginCurrentTrack(autoplay: Bool) {
        // Whatever was prepared was prepared to follow a track that is no longer
        // the one playing. The rebuild below fills the window afresh.
        cancelBlend(resync: false)

        guard let track = queue.currentTrack else {
            finishPlayback()
            return
        }

        // Every caller here is a deliberate user action or a fresh load, never the
        // automatic boundary — so a track being asked for by name earns another try
        // even if it failed earlier. Auto-advance past a dead track still works,
        // because there the failed entry sits behind the head and stays filtered.
        if let id = queue.current?.id { forgetLoadFailures(of: id) }

        // The one moment the decks can take a record: at its beginning. See
        // `shouldUseDecks`.
        if shouldUseDecks(), let entryId = queue.current?.id {
            startOnDecks(track, entryId: entryId, autoplay: autoplay)
            return
        }
        stopDecks()

        beginOnPlayer(track, autoplay: autoplay)
    }

    /// The ordinary path: the queue player, the render window, everything this
    /// engine has always done.
    func beginOnPlayer(_ track: Track, autoplay: Bool) {
        applyLoudness(for: track)

        elapsed = .zero
        duration = track.duration
        exitAt = nil
        lastReportedSecond = -1
        intendsToPlay = autoplay
        state = autoplay ? .buffering : .paused

        // Rebuild rather than advanceToNextItem(): measured, advanceToNextItem
        // inserts ~600ms of real dead air on a deliberate skip, while rebuilding
        // costs ~175ms locally. Over a slow remote server the two converge, so
        // rebuild is the better single choice.
        rebuildWindow(play: autoplay)

        updateNowPlayingInfo()

        openListen(for: track)
    }

    /// Puts back the queue this device was last playing, stopped, where it was.
    ///
    /// Nothing is reported: a queue restored at launch is not a listen, and
    /// counting one would put a play nobody made into the history every time the
    /// app was reopened. `resume()` opens the listen if and when it is played.
    ///
    /// Refuses if anything is already queued — the car can connect and start
    /// something before the phone's own screen has ever run, and taking that
    /// away would be worse than not restoring at all.
    public func restore(_ tracks: [Track], startingAt index: Int, elapsed: Duration) {
        guard queue.isEmpty, !tracks.isEmpty else { return }
        cancelBlend(resync: false)
        forgetLoadFailures()
        queue.load(tracks, startingAt: index)
        guard let track = queue.currentTrack else { return }

        duration = track.duration
        exitAt = nil
        lastReportedSecond = -1
        intendsToPlay = false
        state = .paused
        reportedStartFor = nil
        applyLoudness(for: track)
        rebuildWindow(play: false)
        if elapsed > .zero { seek(to: elapsed) } else { self.elapsed = .zero }
        updateNowPlayingInfo()
    }

    /// Levels the current track against every other one.
    ///
    /// `AVPlayer.volume` is this app's own fader, separate from the system
    /// volume the hardware buttons move, so it is free to spend on this and the
    /// listener's own control still does what they expect. Reset to unity for a
    /// track with no measurement, or the previous track's attenuation would
    /// quietly follow it.
    func applyLoudness(for track: Track?) {
        applyLoudness(for: track, on: player)
    }

    func applyLoudness(for track: Track?, on deck: AVQueuePlayer) {
        guard let track, let resolve = loudnessResolver, let gain = resolve(track) else {
            deck.volume = 1
            return
        }
        deck.volume = Float(min(1, pow(10, gain / 20)))
    }

    /// Called when the queue runs out.
    func finishPlayback() {
        cancelBlend(resync: false)
        stopDecks()
        emptyPlayer()
        state = .idle
        elapsed = .zero
        duration = nil
        exitAt = nil
        updateNowPlayingInfo()
    }
}

#endif
