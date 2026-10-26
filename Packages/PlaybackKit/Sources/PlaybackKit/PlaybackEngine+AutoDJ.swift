#if os(iOS)

import Foundation

// MARK: - Auto DJ

/// Playing records on the decks: starting one there, driving the automation
/// while it plays, and following the queue when a mix moves it on.
///
/// Auto DJ is shelved but kept: nothing here runs unless ``isAutoDJing`` is on.
/// What to play and when is in `PlaybackEngine+AutoDJPlanning.swift`, how a
/// hand-over is booked in `PlaybackEngine+AutoDJBooking.swift`, and the rare
/// mid-play move onto the decks in `PlaybackEngine+DeckTakeover.swift`.
extension PlaybackEngine {
    /// How long before a mix the incoming record is put on the other deck.
    ///
    /// Longer than a blend's twelve seconds because more has to be true: a file
    /// opened, a grid read, and a plan made — and because a mix booked late is a
    /// mix that does not happen, where a blend booked late merely becomes a cut.
    static let djLead = Duration.seconds(30)

    /// Whether the record now playing should be played on the decks rather than
    /// through the player.
    ///
    /// Decided when a track begins and not revisited, because the decks cannot
    /// take over a record already playing: two engines cannot be joined
    /// sample-accurately mid-track, and a mix of a record we do not control the
    /// clock of is not a mix. So the question is asked once, at the only moment
    /// it can be answered — and the answer is yes only when the *next* record is
    /// already mixable, since playing on the decks buys nothing otherwise.
    func shouldUseDecks() -> Bool {
        guard isAutoDJing else { return false }
        // Every record this device holds and the server has gridded, whether or
        // not a mix follows it.
        //
        // This used to also require the *next* record to be mixable, on the
        // reasoning that the decks bought nothing otherwise. It bought something
        // expensive: a record that turned out to have a mixable one behind it had
        // to be moved onto the decks mid-play, and a listener heard that hand-over
        // as a strange moment in the sound just as "Mix ready" appeared. The
        // decks now play the record from the start, and they perform its
        // hand-over whatever kind it turns out to be — a mix, a crossfade, or a
        // join.
        guard let track = queue.currentTrack, djItem(for: track)?.grid != nil else { return false }
        return true
    }

    /// Starts a record on the decks.
    func startOnDecks(_ track: Track, entryId: UUID, autoplay: Bool) {
        let (mixer, session) = prepareDecks()

        guard let item = djItem(for: track) else {
            beginOnPlayer(track, autoplay: autoplay)
            return
        }

        do {
            try mixer.start()
            try session.start(item, at: djClock())
        } catch {
            // A file that will not open is a file the player should try instead;
            // it knows how to fail out loud, and this does not.
            log.error("Couldn't put \(track.title, privacy: .public) on the decks: \(error.localizedDescription, privacy: .public)")
            djSession = nil
            beginOnPlayer(track, autoplay: autoplay)
            return
        }

        markDecksReady(for: entryId)
        // The scrubber runs to where the set leaves the record, not to where
        // the file ends; a bar that stops at sixty per cent is a bar lying.
        duration = item.sound.map { $0.soundEnd } ?? track.duration
        exitAt = item.exitSeconds.map { .seconds($0) }
        elapsed = .zero
        lastReportedSecond = -1
        intendsToPlay = autoplay
        state = autoplay ? .playing : .paused
        if !autoplay { session.pause(at: djClock()) }

        // The player is not merely idle while the decks have it — it is emptied,
        // so nothing of the old queue is left buffered behind a record it is not
        // playing.
        emptyPlayer()

        updateNowPlayingInfo()
        openListen(for: track)

        startDJTimer()
    }

    /// The mixer and the session, made on first use, with the end of a record
    /// wired to the queue.
    func prepareDecks() -> (mixer: DJMixer, session: DJSession) {
        let mixer = djMixer ?? DJMixer()
        djMixer = mixer
        let session = djSession ?? DJSession(mixer: mixer)
        djSession = session
        session.onTrackEnded = { [weak self] in
            // The record finished with nothing mixed in behind it, which is the
            // ordinary end of a track and not a failure of anything.
            self?.next()
        }
        return (mixer, session)
    }

    /// The decks have `entryId` and nothing is booked after it yet.
    func markDecksReady(for entryId: UUID) {
        djEntryId = entryId
        djScheduledEntryId = nil
        booked = nil
        mixing = nil
        outgoingTrack = nil
        mixState = .ready
    }

    /// The decks' own clock, in seconds. Only advances when audio does.
    func djClock() -> Double {
        guard let time = djMixer?.renderTime, time.sampleRate > 0 else { return 0 }
        return Double(time.sampleTime) / time.sampleRate
    }

    var isUsingDecks: Bool { djSession != nil && djEntryId != nil }

    func startDJTimer() {
        djTimer?.invalidate()
        djLastTick = nil
        // Sixty a second. The decks' own alignment does not depend on this timer
        // — that was settled when the mix was booked — but every step it misses
        // is a step of the fade taken in one jump instead of two, and a shelf
        // moved twenty-four decibels in a few jumps is a click.
        djTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.djTick() }
        }
    }

    func stopDecks() {
        djTimer?.invalidate()
        djTimer = nil
        djSession?.stop()
        djSession = nil
        djMixer?.stop()
        djMixer = nil
        djEntryId = nil
        djScheduledEntryId = nil
        booked = nil
        mixing = nil
        outgoingTrack = nil
        mixState = .off
        // A take-over abandoned halfway would otherwise leave the player turned
        // down for good.
        takeover = nil
        player.volume = 1
    }

    private func djTick() {
        guard let session = djSession, let entryId = djEntryId else { return }
        let now = djClock()
        noteLateTick(of: session, at: now)

        if let moment = takeover {
            runTakeover(moment, at: now)
        }

        session.update(at: now)

        // A mix that has begun means the queue has moved: the record the listener
        // is hearing arrive is the next one, and everything that reads the queue
        // — the lock screen, the car, the history — has to agree.
        if let scheduled = djScheduledEntryId, scheduled != entryId,
           session.phase == .mixing || session.handOvers != djHandOversAtBooking {
            adoptMixedTrack(scheduled, at: now)
            return
        }

        elapsed = .seconds(session.heardPosition(at: now))
        followProgrammedExit(on: session, at: now)
        bookHandoverIfDue(at: now)
        refreshMixState(from: session, at: now)
        reportProgressIfDue(atWholeSecond: Int(elapsed.seconds))
    }

    /// A mix is the one thing here that sounds wrong when the main thread is
    /// busy, and "it crackled" is not a report anybody can act on. This is.
    private func noteLateTick(of session: DJSession, at now: Double) {
        if let last = djLastTick, now - last > 0.2, session.phase == .mixing {
            log.warning("The mix automation was \((now - last) * 1000, privacy: .public)ms late")
        }
        djLastTick = now
    }

    /// The exit is re-decided as the record queued next becomes readable,
    /// and the deck ends the record where it believes the exit is: the
    /// two are kept the same, or the deck ends the record at an exit the
    /// set no longer means and the next one starts cold.
    private func followProgrammedExit(on session: DJSession, at now: Double) {
        guard session.phase == .playing, !session.hasScheduledMix, let track = queue.currentTrack else { return }
        let exit = programmedExit(for: track).map { $0 / 1_000 }
        // Never moved to somewhere already behind the playhead: a record
        // "ended" two seconds ago would end now, with nothing booked.
        let reachable = exit.map { $0 > session.position(at: now) + 2 } ?? true
        if exit != session.exitSeconds, reachable {
            session.setExit(seconds: exit)
            exitAt = exit.map { .seconds($0) }
        }
    }

    private func refreshMixState(from session: DJSession, at now: Double) {
        switch session.phase {
        case .mixing:
            if let mixing {
                mixState = .mixing(mixing, progress: session.mixProgress(at: now) ?? 0)
            } else {
                mixState = .ready
            }
        default:
            // The mix is over; the booking it came from has nothing left to say.
            mixing = nil
            outgoingTrack = nil
            if let booked {
                mixState = .booked(booked)
            } else {
                mixState = .ready
            }
        }
    }

    /// The queue catches up with what the decks are already playing.
    private func adoptMixedTrack(_ entryId: UUID, at now: Double) {
        stopReportingCurrent()
        outgoingTrack = queue.currentTrack
        _ = queue.jump(to: entryId)
        djEntryId = entryId
        djScheduledEntryId = nil
        mixing = booked
        booked = nil
        lastReportedSecond = -1
        // The lock screen is told where the new record is *now*, not where the
        // old one had got to — it extrapolates from whatever it was last given.
        if let session = djSession { elapsed = .seconds(session.heardPosition(at: now)) }
        if let track = queue.currentTrack {
            duration = (track.sound ?? soundResolver?(track))?.soundEnd ?? track.duration
            exitAt = programmedExit(for: track).map { .seconds($0 / 1_000) }
            updateNowPlayingInfo()
            openListen(for: track)
        }
    }
}

#endif
