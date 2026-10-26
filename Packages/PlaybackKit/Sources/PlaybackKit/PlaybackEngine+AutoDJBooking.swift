#if os(iOS)

import Foundation

// MARK: - Auto DJ: booking the hand-over

extension PlaybackEngine {
    /// One pair of records a hand-over is being booked between.
    private struct HandOverBooking {
        let outgoing: Track
        let incoming: RenderSlot
        let item: DJItem
        let session: DJSession
        let now: Double
    }

    /// Books whatever hand-over the next record has earned, once it is close
    /// enough to be worth opening a second file for.
    ///
    /// The order is the whole policy: a mix if the pair can be mixed, a
    /// crossfade if Crossfade is on and the pair suits one, and otherwise a join
    /// — one record ending exactly as the next begins, which on two decks driven
    /// by one clock is a truer gapless than asking a player to advance.
    func bookHandoverIfDue(at now: Double) {
        guard let session = djSession, session.phase == .playing, state.isPlaying else { return }
        let window = queue.renderWindow(count: 2)

        guard window.count == 2, window[1].entryId != window[0].entryId else {
            djScheduledEntryId = nil
            booked = nil
            return
        }
        let next = window[1]
        // The queue moved under a booking: the record booked is not the one
        // coming any more.
        if let scheduled = djScheduledEntryId, scheduled != next.entryId {
            djScheduledEntryId = nil
            booked = nil
        }
        guard djScheduledEntryId == nil, !session.hasScheduledMix else { return }
        guard let track = queue.currentTrack, let item = djItem(for: next.track) else { return }

        // Everything below books against how much of the record is left, so
        // nothing is booked while the answer is "most of it".
        let remaining = remainingSound(of: track) ?? .zero
        guard remaining <= Self.djLead else { return }

        let booking = HandOverBooking(outgoing: track, incoming: next, item: item, session: session, now: now)
        do {
            let wasBooked = try bookHandover(booking)
            recordBooking(booking, wasBooked: wasBooked)
        } catch {
            log.warning("Couldn't book a hand-over: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Books the best hand-over the pair allows and says whether the session
    /// took it. ``booked`` names what was tried either way.
    private func bookHandover(_ booking: HandOverBooking) throws -> Bool {
        if let transition = plannedMix(from: booking.outgoing, to: booking.incoming.track, position: elapsed) {
            return try bookMix(transition, booking)
        }
        if let cut = plannedCut(from: booking.outgoing, to: booking.incoming.track, position: elapsed) {
            // Read, and refused a mix: too far apart in tempo, or both
            // singing. A pair like that is cut on the phrase line, the way a
            // DJ would, rather than crossfaded across each other's voices.
            return try bookCut(cut, booking)
        }
        return try bookCrossfadeOrJoin(booking)
    }

    private func bookMix(_ transition: DJTransition, _ booking: HandOverBooking) throws -> Bool {
        let session = booking.session
        let wasBooked = try session.schedule(transition, into: booking.item, at: booking.now)
        booked = .mix(transition.style, bars: transition.bars)
        // The set leaves where the mix ends, which the planner chose
        // for this pair; the deck's own end and the mark on the bar
        // follow it, so that a booking abandoned by a pause does not
        // leave the deck ending the record at an exit the plan had
        // moved past.
        let leaves = transition.outgoingStartMs / 1_000 + transition.seconds
        session.setExit(seconds: leaves)
        exitAt = .seconds(leaves)
        log.info("Mixing \(booking.outgoing.title, privacy: .public) into \(booking.incoming.track.title, privacy: .public) over \(transition.bars) bars")
        return wasBooked
    }

    private func bookCut(_ cut: DJTransition, _ booking: HandOverBooking) throws -> Bool {
        let session = booking.session
        let wasBooked = try session.schedule(cut, into: booking.item, at: booking.now)
        booked = .mix(cut.style, bars: 0)
        session.setExit(seconds: cut.outgoingStartMs / 1_000)
        exitAt = .seconds(cut.outgoingStartMs / 1_000)
        // Enough in the log to say why it was this and not the other:
        // the exit chosen, whether the record had lyrics to read, and
        // where the new one lands.
        let track = booking.outgoing
        let hadLyrics = lyricLinesResolver?(track) != nil
        log.info("\(cut.style == .echoOut ? "Echoing out of" : "Filtered cut from", privacy: .public) \(track.title, privacy: .public) at \(Int(cut.outgoingStartMs), privacy: .public) ms (lyrics \(hadLyrics ? "read" : "none", privacy: .public)) into \(booking.incoming.track.title, privacy: .public) at \(Int(cut.incomingStartMs), privacy: .public) ms")
        return wasBooked
    }

    private func bookCrossfadeOrJoin(_ booking: HandOverBooking) throws -> Bool {
        let plan = MixPlanner.plan(
            from: mixTrack(booking.outgoing),
            to: mixTrack(booking.incoming.track),
            automix: isCrossfading,
            albumLock: isAlbumLocked
        )
        // Named too, so the screen can say "Crossfade" rather than
        // nothing when that is what is coming — a listener who has
        // both switches on wants to know which one is about to act.
        switch plan {
        case .blend(let overlap):
            let wasBooked = try booking.session.scheduleBlend(seconds: overlap.seconds, into: booking.item, at: booking.now)
            booked = .crossfade(seconds: overlap.seconds)
            return wasBooked
        case .gapless, .cut:
            let wasBooked = try booking.session.scheduleJoin(into: booking.item, at: booking.now)
            booked = .join
            return wasBooked
        }
    }

    /// Nothing booked is nothing to wait for: the next tick asks
    /// again from wherever the record then is. Taking silence for a
    /// booking left the record to end with nothing behind it.
    private func recordBooking(_ booking: HandOverBooking, wasBooked: Bool) {
        let next = booking.incoming
        guard wasBooked else {
            booked = nil
            // Once per pair, not sixty times a second.
            if djUnbookable != next.entryId {
                djUnbookable = next.entryId
                log.warning("Nothing could be booked from \(booking.outgoing.title, privacy: .public) into \(next.track.title, privacy: .public) yet")
            }
            return
        }
        djUnbookable = nil
        djScheduledEntryId = next.entryId
        djHandOversAtBooking = booking.session.handOvers
    }
}

#endif
