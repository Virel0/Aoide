#if os(iOS)

import Foundation

// MARK: - Auto DJ: taking a record onto the decks mid-play

extension PlaybackEngine {
    /// Taking a record off the player and onto the decks, mid-play.
    ///
    /// **The rare path.** The decks now take every gridded local record from its
    /// beginning, so this is only reached when Auto DJ is switched on while
    /// something is already playing, or when a record's grid arrives after it
    /// started. It used to be the ordinary path, and a listener heard it: two
    /// engines playing the same instant of the same file drift against each
    /// other by a few milliseconds, and two copies of one recording a few
    /// milliseconds apart is a comb filter — which sounds like the volume doing
    /// something strange, exactly as it was described.
    ///
    /// It is kept because the alternative is refusing to mix for the rest of a
    /// record somebody just turned the feature on during, and it is now
    /// abandoned at the first sign of trouble rather than pressed through.
    struct DeckTakeover {
        let startsAt: Double
        let endsAt: Double
    }

    /// How far ahead the deck is booked when taking a record over.
    private static let takeoverLead = 0.35
    /// And how long the two are crossfaded across.
    private static let takeoverFade = 0.3

    /// Asked on every time update while the player still has the record.
    func considerDeckTakeover() {
        guard isAutoDJing, !isUsingDecks, takeover == nil, state.isPlaying, blend == nil else { return }
        guard let entryId = queue.current?.id,
              let track = queue.currentTrack,
              let item = djItem(for: track)
        else { return }

        let window = queue.renderWindow(count: 2)
        guard window.count == 2, window[1].entryId != entryId else { return }

        // Planned from where the record will be once the hand-over is done, not
        // from where it is now.
        let after = elapsed + .seconds(Self.takeoverLead + Self.takeoverFade)
        guard let transition = plannedMix(from: track, to: window[1].track, position: after) else { return }
        // Only worth moving a record for a mix that is actually close.
        guard transition.outgoingStartMs - elapsed.seconds * 1_000 <= Self.djLead.seconds * 1_000 else { return }

        beginTakeover(track, entryId: entryId, item: item)
    }

    private func beginTakeover(_ track: Track, entryId: UUID, item: DJItem) {
        let (mixer, session) = prepareDecks()

        do {
            try mixer.start()
            // A deck can only be booked against a clock that is running. Before
            // the engine has rendered anything there is no clock, the booking is
            // silently dropped, and what follows is a player faded out under a
            // deck that never started — silence, and then a stall. Wait a tick.
            guard mixer.renderTime != nil else { return }
            // The units' own latency comes off the content position: the deck
            // is booked for a moment, and what reaches the speaker at that
            // moment left the file that much earlier.
            let booked = try session.start(
                item,
                from: elapsed.seconds + Self.takeoverLead - mixer.latency,
                at: djClock(),
                inSeconds: Self.takeoverLead
            )
            guard booked else {
                log.warning("The decks would not take \(track.title, privacy: .public); leaving it on the player")
                session.stop()
                djSession = nil
                return
            }
        } catch {
            log.warning("Couldn't take \(track.title, privacy: .public) onto the decks: \(error.localizedDescription, privacy: .public)")
            djSession = nil
            return
        }

        let now = djClock()
        takeover = DeckTakeover(startsAt: now + Self.takeoverLead, endsAt: now + Self.takeoverLead + Self.takeoverFade)
        markDecksReady(for: entryId)
        log.info("Taking \(track.title, privacy: .public) onto the decks at \(self.elapsed.seconds, privacy: .public)s")
        startDJTimer()
    }

    /// Rides the two across each other, then empties the player.
    func runTakeover(_ moment: DeckTakeover, at now: Double) {
        guard let session = djSession else { return }
        let progress = (now - moment.startsAt) / (moment.endsAt - moment.startsAt)

        guard progress < 1 else {
            session.setCurrentVolume(scale: 1)
            emptyPlayer()
            player.volume = 1
            takeover = nil
            return
        }
        guard progress >= 0 else { return }

        // The same equal-power curve as everything else here, for the same
        // reason: two copies of one recording at half volume are not one copy at
        // full volume.
        player.volume = Float(MixCurve.outgoing(progress: progress))
        session.setCurrentVolume(scale: MixCurve.incoming(progress: progress))
    }
}

#endif
