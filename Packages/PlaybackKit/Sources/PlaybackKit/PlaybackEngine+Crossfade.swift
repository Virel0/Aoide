#if os(iOS)

import AVFoundation
import Foundation

// MARK: - Crossfade: deciding and preparing

/// Whether to blend into the next track, and getting it ready on the spare deck.
/// Starting, finishing and abandoning a blend are in
/// `PlaybackEngine+CrossfadeHandOver.swift`.
extension PlaybackEngine {
    /// A crossfade, from the moment the incoming track is put on the spare deck
    /// to the moment that deck becomes the player.
    struct Blend {
        let entryId: UUID
        let track: Track
        let overlap: Duration
        /// The item on the spare deck, once it exists.
        var itemKey: ObjectIdentifier?
        /// Whether the incoming track's fade-in has been attached. A blend whose
        /// fade is not ready in time becomes a cut rather than a track arriving
        /// at full volume over the one still playing.
        var isFadeReady = false
        /// Whether the incoming track is audible yet.
        var isRunning = false
        /// Where the outgoing deck's own fader started, so the fade-out is applied
        /// on top of that track's loudness levelling rather than instead of it.
        var outgoingVolume: Float = 1
    }

    /// How long before a blend the incoming track is put on the spare deck.
    ///
    /// A remote track cannot be started from nothing at the instant it is wanted
    /// — it has to be fetched and decoded first — and a blend that begins with
    /// silence is worse than no blend. Twelve seconds is comfortably more than a
    /// track needs to become ready on a slow connection, and short enough that a
    /// listener skipping around rarely pays for a preparation nobody used.
    private static let blendLead = Duration.seconds(12)

    /// Runs on every time update while something is playing: decides whether a
    /// blend should be prepared, started, or abandoned.
    ///
    /// Driven from the clock rather than scheduled ahead, because everything it
    /// depends on can change under it — the queue can be reordered, the next track
    /// can be removed, the toggle can go off — and a decision re-taken twice a
    /// second cannot go stale.
    func considerBlend() {
        let window = queue.renderWindow(count: 2)

        // Nothing to hand over to, or repeat-one, which would blend a track into
        // itself. Either way, anything prepared is no longer wanted.
        guard window.count == 2, window[1].entryId != window[0].entryId, let current = queue.currentTrack else {
            cancelBlend()
            return
        }
        let next = window[1]

        if let blend {
            // The queue moved on under a prepared blend: the track it was going to
            // bring in is not the one coming next any more.
            guard blend.entryId == next.entryId else {
                cancelBlend()
                return
            }
            guard !blend.isRunning, state.isPlaying else { return }
            guard let remaining = remainingSound(of: current), remaining <= blend.overlap else { return }
            // The moment has come. If the incoming track is not ready to arrive
            // from silence, it does not arrive at all — better the plain cut this
            // player has always done than a second song at full volume over the
            // first.
            if blend.isFadeReady {
                startBlend()
            } else {
                log.warning("The blend wasn't ready in time; cutting instead")
                cancelBlend()
            }
            return
        }

        guard state.isPlaying else { return }
        guard case let .blend(overlap) = MixPlanner.plan(
            from: mixTrack(current),
            to: mixTrack(next.track),
            automix: isCrossfading,
            albumLock: isAlbumLocked
        ) else { return }
        guard let remaining = remainingSound(of: current),
              remaining <= overlap + Self.blendLead
        else { return }

        armBlend(next, overlap: overlap)
    }

    /// What the planner needs to know about a track, filled in from the same
    /// caches the player itself reads.
    func mixTrack(_ track: Track) -> MixTrack {
        MixTrack(
            album: track.album,
            trackNumber: track.trackNumber,
            duration: track.duration,
            sound: track.sound ?? soundResolver?(track),
            bpm: tempoResolver?(track)?.bpm,
            bpmStability: tempoResolver?(track)?.stability
        )
    }

    /// How much sound is left in the track playing now, measured to wherever the
    /// player will actually stop — the sound's end when it has been measured, and
    /// the file's end when it has not.
    func remainingSound(of track: Track) -> Duration? {
        let end: Duration
        if let exit = programmedExit(for: track) {
            end = .seconds(exit / 1_000)
        } else if let sound = track.sound ?? soundResolver?(track) {
            end = sound.soundEnd
        } else if let duration {
            end = duration
        } else {
            return nil
        }
        return end > elapsed ? end - elapsed : .zero
    }

    /// Puts the incoming track on the spare deck, silent and ready, and takes it
    /// out of this deck's window so the outgoing track runs out of things to
    /// advance to.
    private func armBlend(_ slot: RenderSlot, overlap: Duration) {
        blend = Blend(entryId: slot.entryId, track: slot.track, overlap: overlap)
        mixState = .booked(.crossfade(seconds: overlap.seconds))
        syncPlayer()

        let item = makeItem(for: slot.track, entryId: slot.entryId)
        blend?.itemKey = ObjectIdentifier(item)
        spareDeck.removeAllItems()
        spareDeck.insert(item, after: nil)
        spareDeck.pause()
        applyLoudness(for: slot.track, on: spareDeck)

        prepareFadeIn(item, of: slot.track, overlap: overlap)
        log.info("Blending in \(slot.track.title, privacy: .public) over \(overlap.seconds, privacy: .public)s")
    }

    /// Attaches the incoming track's fade-in before it plays a note.
    ///
    /// Asynchronous because the fade has to be attached to the asset's own audio
    /// track, and for a streamed file that track is not known until some of the
    /// file has been read. That is the reason a blend is prepared seconds ahead
    /// rather than at the moment it is wanted.
    ///
    /// Only the incoming half is done this way. An `AVAudioMix` is sample-accurate
    /// and immune to a busy main thread, but AVFoundation only promises to honour
    /// one that was attached *before* the item played — which the outgoing track,
    /// by definition, already has. Its half is ridden down on the deck's fader
    /// instead; see ``startBlend()``.
    private func prepareFadeIn(_ item: AVPlayerItem, of track: Track, overlap: Duration) {
        let key = ObjectIdentifier(item)
        let seconds = overlap.seconds
        let start = (track.sound ?? soundResolver?(track))?.soundStart ?? .zero

        Task { @MainActor [weak self] in
            let mix = await Self.audioTrack(of: item).flatMap {
                MixRamp.fadeIn(track: $0, startingAt: start.cmTime, seconds: seconds)
            }
            guard let self, self.blend?.itemKey == key else { return }
            guard let mix else {
                self.log.warning("Couldn't build a fade-in; cutting instead")
                self.cancelBlend()
                return
            }
            item.audioMix = mix
            self.blend?.isFadeReady = true
        }
    }

    private static func audioTrack(of item: AVPlayerItem) async -> AVAssetTrack? {
        try? await item.asset.loadTracks(withMediaType: .audio).first
    }
}

#endif
