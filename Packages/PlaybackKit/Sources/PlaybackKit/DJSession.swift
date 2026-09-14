import AVFoundation
import Foundation

/// One record on a deck, with everything already known about it.
public struct DJItem: Equatable, Sendable {
    /// A file on this device. Streamed tracks do not come here.
    public let url: URL
    /// Where the sound is, if it has been measured.
    public let sound: SilenceBounds?
    /// Decibels of levelling, from ``LoudnessNormalisation``.
    public let gainDb: Double?
    /// Where its beats are, if the server has measured them.
    public let grid: BeatGrid?
    /// Where the set leaves this record, when a set is being programmed. Before
    /// the sound ends, usually well before: see ``SetProgrammer``. Moved by
    /// ``DJSession/setExit(seconds:)`` as the set changes its mind.
    public var exitSeconds: Double?

    public init(url: URL, sound: SilenceBounds? = nil, gainDb: Double? = nil, grid: BeatGrid? = nil, exitSeconds: Double? = nil) {
        self.url = url
        self.sound = sound
        self.gainDb = gainDb
        self.grid = grid
        self.exitSeconds = exitSeconds
    }

    var startSeconds: Double { (sound?.soundStart.seconds).map { max(0, $0) } ?? 0 }
    /// Where playing this record stops: the programmed exit if there is one,
    /// otherwise the end of its sound.
    var endSeconds: Double? { exitSeconds ?? sound?.soundEnd.seconds }
    var linearGain: Double {
        guard let gainDb, gainDb < 0 else { return 1 }
        return min(1, pow(10, gainDb / 20))
    }
}

/// Plays records on ``DJMixer`` and mixes one into the next.
///
/// The layer between "here is a plan" and "here are two decks": it owns which
/// side is playing, when the next one starts, and what the faders and shelves
/// are doing at each moment of a mix.
///
/// Driven by a clock rather than by timers of its own — ``update(at:)`` is
/// called with the mixer's render time, which only advances when audio does.
/// A busy main thread makes the automation coarse; it cannot make it wrong, and
/// it cannot make the two decks drift, because the decks were scheduled against
/// that same clock once and are not touched again.
///
/// Platform-free on purpose, so a whole mix can be rendered offline and
/// measured. See `DJSessionTests`.
public final class DJSession {
    public enum Phase: Equatable, Sendable {
        case idle
        /// One record playing, nothing planned.
        case playing
        /// Two records playing, the first on its way out.
        case mixing
    }

    private let mixer: DJMixer
    private var side: DJMixer.Side = .a
    private var other: DJMixer.Side { side == .a ? .b : .a }

    /// Which deck holds the record that is playing. Exposed because "did the
    /// handover happen" is otherwise unobservable from outside.
    public var playingSide: DJMixer.Side { side }

    /// Whether a mix is booked but has not begun.
    public var hasScheduledMix: Bool { mix != nil }

    /// Whether what is booked is a beat-matched mix rather than a fade or a join.
    public var hasScheduledBeatMatch: Bool { mix?.transition != nil }

    /// How far through a mix the decks are, 0…1, or nothing if none is running.
    /// A screen can draw a crossfader with this.
    public func mixProgress(at sessionSeconds: Double) -> Double? {
        guard let mix, mix.endsAt > mix.beginsAt, sessionSeconds >= mix.beginsAt else { return nil }
        return min(1, max(0, (sessionSeconds - mix.beginsAt) / (mix.endsAt - mix.beginsAt)))
    }

    public private(set) var phase: Phase = .idle

    /// How many records have been handed over since the session began. A
    /// hand-over with no length — a join, a plain cut — begins and ends
    /// between two ticks, so nobody watching ``phase`` sees it; this does not
    /// go back.
    public private(set) var handOvers = 0

    /// The session clock, in seconds, at which the record now playing began.
    private var startedAt: Double = 0
    /// Where in that record playback began.
    private var startOffset: Double = 0
    private var current: DJItem?

    /// What is booked onto the other deck, if anything.
    private var mix: Mix?

    /// The session time at which a bend must be finished being eased out.
    private var restoreEndsAt: Double?

    /// Whether a booked cut has fallen. Set on the first tick past its moment,
    /// so the echo is started exactly once.
    private var cutStarted = false

    /// A hand-over booked onto the other deck.
    ///
    /// Three kinds, and the decks perform all three. That is the point of them
    /// owning playback rather than only owning mixes: a join between two records
    /// on one clock is sample-accurate, which is a better gapless than the queue
    /// player's, and a plain crossfade needs the same two decks a mix does.
    private struct Mix {
        enum Kind {
            /// Beat-matched, bar-aligned, bass swapped. See ``DJTransition``.
            case mixed(DJTransition)
            /// Two records overlapping for this long, on volume alone.
            case blended(Double)
            /// One record ending exactly as the next begins.
            case joined
            /// The outgoing record stops on a phrase line as the incoming one
            /// starts, its last beat left ringing for `tail` seconds if the
            /// transition is an echo-out, or not at all if it is a cut.
            case cut(DJTransition, tail: Double)

            /// Only a mix holds the incoming record's low end back; a crossfade
            /// that did would be taking the bottom out of a fade for no reason.
            var cutsIncomingBass: Bool {
                if case .mixed = self { return true }
                return false
            }

            /// Whether the two records sound together at all.
            var overlaps: Bool {
                if case .cut = self { return false }
                return true
            }
        }

        let kind: Kind
        let incoming: DJItem
        /// Session time the incoming record begins. Moved later by a pause.
        var startsAt: Double
        /// Session time the outgoing record is finished with. Moved with it.
        var endsAt: Double
        /// Where the incoming record was started from.
        let incomingOffset: Double
        /// How long before the incoming record the outgoing one is cut — an
        /// echo-out's bridge. Zero for everything else: the mix begins when
        /// the incoming record does.
        var cutLead: Double = 0
        /// How long before the cut the echo is brought in under the record.
        var echoLead: Double = 0

        /// When the automation begins: the cut, for an echo-out; otherwise
        /// the incoming record's start.
        var beginsAt: Double { startsAt - cutLead }
        /// When the echo starts to build under the record, before the cut.
        var armsAt: Double { beginsAt - echoLead }

        var transition: DJTransition? {
            if case let .mixed(transition) = kind { return transition }
            return nil
        }
    }

    /// Called when the record playing reaches the end of its sound with nothing
    /// mixed in behind it.
    public var onTrackEnded: (() -> Void)?

    public init(mixer: DJMixer = DJMixer()) {
        self.mixer = mixer
    }

    // MARK: - Playing

    /// Starts a record now, on whichever deck is free.
    public func start(_ item: DJItem, at sessionSeconds: Double) throws {
        try start(item, from: item.startSeconds, at: sessionSeconds)
    }

    /// Starts a record from a given point, optionally a moment from now.
    ///
    /// The lead exists for taking a record over from the ordinary player, which
    /// cannot be stopped and started to the sample: the deck is booked for a
    /// moment in the near future with the content position that will be true
    /// *then*, so the two are playing the same instant of the same record when
    /// they cross.
    @discardableResult
    public func start(
        _ item: DJItem,
        from seconds: Double,
        at sessionSeconds: Double,
        inSeconds lead: Double = 0
    ) throws -> Bool {
        try mixer.load(item.url, on: side, from: seconds)
        mixer.setVolume(lead > 0 ? 0 : item.linearGain, on: side)
        mixer.setBassCut(0, on: side)
        mixer.setRate(1, on: side)
        var started = true
        if lead > 0 {
            // Nothing to book against means nothing was booked, and a caller that
            // believes otherwise fades the player out under silence.
            started = mixer.play(side, inSeconds: lead) != nil
        } else {
            mixer.play(side)
        }
        current = item
        startedAt = sessionSeconds + lead
        startOffset = seconds
        phase = .playing
        mix = nil
        return started
    }

    /// Scales the playing deck against the record's own levelling, for a fade
    /// that belongs to something other than a mix.
    public func setCurrentVolume(scale: Double) {
        mixer.setVolume((current?.linearGain ?? 1) * max(0, min(1, scale)), on: side)
    }

    /// Where the record playing has got to, in its own timeline.
    ///
    /// Computed from the session clock, not read off the deck: the player
    /// node's own frame count runs ahead of what is audible by however much
    /// the time-pitch unit has pulled in advance, and a booking made against
    /// that would land the incoming record early by the same amount. The
    /// clock is the output's clock, so this is exact for booking — provided
    /// the arithmetic is honest about the two things that used to make it
    /// drift: the rate is folded in every time it changes (a record eased
    /// back to its own tempo is not "the whole time at the rate it has now"),
    /// and a pause stops the count.
    ///
    /// During a mix this is still the *outgoing* record: the booking and the
    /// end-of-sound arithmetic are in its terms until it stops. A screen wants
    /// ``heardPosition(at:)``.
    public func position(at sessionSeconds: Double) -> Double {
        startOffset + max(0, played(until: sessionSeconds) - startedAt) * mixer.rate(on: side)
    }

    /// Where the record the listener is *arriving at* has got to.
    ///
    /// The same as ``position(at:)`` except during a mix, when it follows the
    /// incoming record from the moment it started under the outgoing one. The
    /// queue moves on to the incoming record as the mix begins, so a progress
    /// bar reading the outgoing record's position against the incoming one's
    /// length sat pinned at the end for the length of the mix, then jumped back.
    public func heardPosition(at sessionSeconds: Double) -> Double {
        guard phase == .mixing, let mix else { return position(at: sessionSeconds) }
        return mix.incomingOffset + max(0, played(until: sessionSeconds) - mix.startsAt) * mixer.rate(on: other)
    }

    /// The clock as far as the records are concerned: it stops at a pause.
    private func played(until sessionSeconds: Double) -> Double {
        min(sessionSeconds, pausedAt ?? sessionSeconds)
    }

    /// Changes the playing deck's rate, first folding what it played at the
    /// old rate into the offset so the position does not rewrite history.
    private func setPlayingRate(_ rate: Double, at sessionSeconds: Double) {
        guard abs(mixer.rate(on: side) - rate) > 0.0001 else { return }
        startOffset = position(at: sessionSeconds)
        startedAt = played(until: sessionSeconds)
        mixer.setRate(rate, on: side)
    }

    /// The session clock when playback was paused, so what is booked against
    /// that clock can be moved by exactly the time it stood still.
    private var pausedAt: Double?

    /// Moves where the record playing is left — or clears it, so it plays to
    /// the end of its sound.
    ///
    /// The exit is decided again as the set learns more: the record queued
    /// next arrives, is read, turns out not to mix, and the set decides to
    /// play this one to its last hook instead. The deck ends the record where
    /// *it* believes the exit is, so it has to be told — a record ended at
    /// the first exit while the hand-over was booked against the second
    /// simply stopped, and the next one started cold.
    public func setExit(seconds: Double?) {
        current?.exitSeconds = seconds
    }

    /// Where the record playing is left, as the deck has it.
    public var exitSeconds: Double? { current?.exitSeconds }

    /// Books a beat-matched mix somebody else planned.
    ///
    /// The booking is the part that has to be exact, and it is done once, here,
    /// against the mixer's own clock — after this the two decks are running and
    /// nothing that happens on the main thread can pull them apart.
    /// Whether it was booked. Nothing is booked when the moment has passed
    /// or a hand-over is already on the decks, and a caller that took silence
    /// for a booking waited for a hand-over that never came.
    @discardableResult
    public func schedule(_ transition: DJTransition, into incoming: DJItem, at sessionSeconds: Double) throws -> Bool {
        let untilStart = (transition.outgoingStartMs / 1000 - position(at: sessionSeconds)) / rate
        guard transition.style.overlaps else {
            let echo = transition.style == .echoOut
            let tail = echo ? DJPlanner.echoTailSeconds(targetBpm: transition.targetBpm) : 0
            let gap = echo ? DJPlanner.echoGapSeconds(targetBpm: transition.targetBpm) : 0
            let lead = echo ? DJPlanner.echoLeadSeconds(targetBpm: transition.targetBpm) : 0
            return try book(
                .cut(transition, tail: tail),
                into: incoming,
                from: transition.incomingStartMs / 1000,
                startingIn: untilStart + gap,
                cutLead: gap,
                echoLead: lead,
                lasting: tail,
                rate: 1,
                at: sessionSeconds
            )
        }
        return try book(
            .mixed(transition),
            into: incoming,
            from: transition.incomingStartMs / 1000,
            startingIn: untilStart,
            lasting: transition.seconds,
            rate: transition.incomingRate,
            at: sessionSeconds
        )
    }

    /// Books a plain crossfade of `seconds`, ending as the outgoing record does.
    ///
    /// Shortened to what is left when the record ends sooner than the fade is
    /// long — the exit can move under a booking that was due — because a
    /// shorter fade is a fade and no fade is a cold start.
    @discardableResult
    public func scheduleBlend(seconds: Double, into incoming: DJItem, at sessionSeconds: Double) throws -> Bool {
        guard let untilEnd = untilEnd(at: sessionSeconds) else { return false }
        let fits = min(seconds, max(0, untilEnd - Self.soonestBooking))
        guard fits > 0.5 else { return false }
        return try book(
            .blended(fits),
            into: incoming,
            from: incoming.startSeconds,
            startingIn: untilEnd - fits,
            lasting: fits,
            rate: 1,
            at: sessionSeconds
        )
    }

    /// How far ahead a hand-over can be booked at the earliest: the file has
    /// to be opened and the deck spun up.
    static let soonestBooking = 0.25

    /// Books the next record to begin exactly as this one ends.
    ///
    /// What an album run gets, and what everything else gets when nothing longer
    /// was planned. Two records on one clock join to the sample, so this is a
    /// truer gapless than a player that has to be asked to advance.
    @discardableResult
    public func scheduleJoin(into incoming: DJItem, at sessionSeconds: Double) throws -> Bool {
        guard let untilEnd = untilEnd(at: sessionSeconds) else { return false }
        return try book(
            .joined,
            into: incoming,
            from: incoming.startSeconds,
            startingIn: untilEnd,
            lasting: 0,
            rate: 1,
            at: sessionSeconds
        )
    }

    /// How long until the record playing reaches the end of its sound.
    private func untilEnd(at sessionSeconds: Double) -> Double? {
        guard let end = current?.endSeconds else { return nil }
        return (end - position(at: sessionSeconds)) / rate
    }

    private var rate: Double { mixer.rate(on: side) }

    private func book(
        _ kind: Mix.Kind,
        into incoming: DJItem,
        from offset: Double,
        startingIn lead: Double,
        cutLead: Double = 0,
        echoLead: Double = 0,
        lasting seconds: Double,
        rate incomingRate: Double,
        at sessionSeconds: Double
    ) throws -> Bool {
        guard phase == .playing, mix == nil, lead - cutLead > 0 else { return false }

        try mixer.load(incoming.url, on: other, from: offset)
        mixer.clearEcho(other)
        // The state the deck must be in for its first instant, before any
        // automation has run. `update` overwrites both a tick later, so this only
        // governs the moment between the deck starting and the first tick after
        // it — which is exactly the moment a record would otherwise arrive at
        // full volume. A cut is the exception: the new record arrives at full
        // on purpose, that being the point of a cut.
        mixer.setVolume(seconds > 0 && kind.overlaps ? 0 : incoming.linearGain, on: other)
        mixer.setBassCut(kind.cutsIncomingBass ? 1 : 0, on: other)
        mixer.setRate(incomingRate, on: other)
        mixer.play(other, inSeconds: lead)

        mix = Mix(
            kind: kind,
            incoming: incoming,
            startsAt: sessionSeconds + lead,
            // Measured from where the automation begins — the cut, for an
            // echo-out — so a tail is a tail from the moment the record stops.
            endsAt: sessionSeconds + lead - cutLead + seconds,
            incomingOffset: offset,
            cutLead: cutLead,
            echoLead: echoLead
        )
        return true
    }

    /// Runs the automation. Call as often as convenient; missing a call makes the
    /// fade coarser and nothing else.
    public func update(at sessionSeconds: Double) {
        easeRateBack(at: sessionSeconds)

        guard let mix else {
            endTrackIfFinished(at: sessionSeconds)
            return
        }
        guard sessionSeconds >= mix.beginsAt else {
            // An echo-out's approach: the record still playing, the echo
            // building under its last beats, so that by the line the dry
            // signal has already gone and the cut stops nothing audible.
            if case .cut(let transition, _) = mix.kind, mix.echoLead > 0, sessionSeconds >= mix.armsAt {
                let approach = (sessionSeconds - mix.armsAt) / mix.echoLead
                mixer.armEcho(side, beatSeconds: 60 / transition.targetBpm, wet: 100 * max(0, min(1, approach)))
            }
            return
        }
        guard sessionSeconds < mix.endsAt else {
            finish(mix, at: sessionSeconds)
            return
        }

        phase = .mixing
        let progress = mix.endsAt > mix.beginsAt ? (sessionSeconds - mix.beginsAt) / (mix.endsAt - mix.beginsAt) : 1

        switch mix.kind {
        case .cut(let transition, let tail):
            // A plain cut never reaches here: it ends the instant it begins and
            // `finish` stops the outgoing deck. Only an echo-out has a tail to
            // run, and its first tick is where the ring is started.
            if !cutStarted, tail > 0 {
                cutStarted = true
                mixer.echoOut(side, beatSeconds: 60 / transition.targetBpm)
            }
            // The repeats decay on the feedback; the fader stays open for
            // most of the tail and closes over the last of it, so the ring
            // ends rather than being cut off a second time. And the low end
            // is swept out of the repeats across the gap, so by the time the
            // new record's kick lands there is not one still ringing under it.
            if tail > 0 {
                let fade = max(0, min(1, (progress - DJPlanner.echoFadeFrom) / (1 - DJPlanner.echoFadeFrom)))
                mixer.setVolume((1 - fade) * (current?.linearGain ?? 1), on: side)
                let gap = mix.cutLead > 0 ? (sessionSeconds - mix.beginsAt) / mix.cutLead : 1
                mixer.setHighPass(
                    hz: DJAutomation.sweep(from: Double(DJMixer.bassOpenHz), to: DJPlanner.echoHighPassHz, fraction: gap),
                    on: side
                )
            }
        case .mixed(let transition):
            // The levelling sits underneath the mix's own curve, so two records
            // brought to one loudness stay there while they cross.
            mixer.setVolume(DJAutomation.outgoingGain(progress: progress) * (current?.linearGain ?? 1), on: side)
            mixer.setVolume(DJAutomation.incomingGain(progress: progress) * mix.incoming.linearGain, on: other)
            mixer.setHighPass(hz: DJAutomation.outgoingHighPassHz(progress: progress, style: transition.style), on: side)
            mixer.setHighPass(hz: DJAutomation.incomingHighPassHz(progress: progress), on: other)
            mixer.setRate(transition.incomingRate, on: other)
        case .blended:
            // No bass swap and no bend: a crossfade between two records that were
            // never claimed to fit is a fade, and dressing it up as a mix would
            // be dressing up a guess.
            mixer.setVolume(MixCurve.outgoing(progress: progress) * (current?.linearGain ?? 1), on: side)
            mixer.setVolume(MixCurve.incoming(progress: progress) * mix.incoming.linearGain, on: other)
        case .joined:
            break
        }
    }

    /// The mix is over: the outgoing deck is silent and is stopped, and the
    /// record that came in is simply the record playing.
    private func finish(_ mix: Mix, at sessionSeconds: Double) {
        mixer.setVolume(0, on: side)
        mixer.stopDeck(side)
        mixer.clearEcho(side)
        mixer.setHighPass(hz: Double(DJMixer.bassOpenHz), on: side)
        cutStarted = false
        mixer.setBassCut(0, on: other)
        mixer.setVolume(mix.incoming.linearGain, on: other)

        side = other
        current = mix.incoming
        handOvers += 1
        startOffset = mix.incomingOffset
        // The incoming deck has been running since the mix began, at its bent
        // rate, so its clock did not start now — it started then.
        startedAt = mix.startsAt
        phase = .playing
        self.mix = nil

        // Bent to meet the record that has just ended; it gets its own tempo back
        // over the next few seconds rather than keeping somebody else's forever.
        if let transition = mix.transition, transition.incomingRate != 1 {
            restoreEndsAt = sessionSeconds + transition.restoreSeconds
            restoreFrom = transition.incomingRate
            restoreStartedAt = sessionSeconds
        }
    }

    private var restoreFrom: Double = 1
    private var restoreStartedAt: Double = 0

    /// Eases a bent record back to its own speed.
    ///
    /// Linear in rate over the whole restore, which is inaudible at these
    /// distances — a per cent spread across eight seconds is slower than the
    /// drift of a record deck warming up.
    private func easeRateBack(at sessionSeconds: Double) {
        guard let ends = restoreEndsAt else { return }
        guard sessionSeconds < ends else {
            setPlayingRate(1, at: sessionSeconds)
            restoreEndsAt = nil
            return
        }
        let progress = (sessionSeconds - restoreStartedAt) / (ends - restoreStartedAt)
        setPlayingRate(restoreFrom + (1 - restoreFrom) * progress, at: sessionSeconds)
    }

    private func endTrackIfFinished(at sessionSeconds: Double) {
        guard phase == .playing, let current, let end = current.endSeconds else { return }
        guard position(at: sessionSeconds) >= end else { return }
        phase = .idle
        mixer.stopDeck(side)
        onTrackEnded?()
    }

    // MARK: - Transport

    /// Stops both decks where they are.
    ///
    /// A mix booked but not begun is abandoned: the incoming deck was told to
    /// start at a moment on the engine's clock, and the clock does not pause
    /// with the record — it would have come in on its own, over silence, at
    /// the booked time. Whoever booked it books again after the resume, from
    /// where the record then is.
    public func pause(at sessionSeconds: Double) {
        if phase == .playing, mix != nil {
            mixer.stopDeck(other)
            // An echo already building under the record goes with the booking.
            mixer.clearEcho(side)
            mix = nil
        }
        pausedAt = sessionSeconds
        mixer.pauseAll()
    }

    /// Starts both decks again, and moves everything measured against the
    /// session clock — a mix in progress, a tempo being eased back — later by
    /// the time they stood still, so nothing finishes early.
    public func resume(at sessionSeconds: Double) {
        if let pausedAt {
            let stood = max(0, sessionSeconds - pausedAt)
            startedAt += stood
            if mix != nil {
                mix?.startsAt += stood
                mix?.endsAt += stood
            }
            if restoreEndsAt != nil {
                restoreEndsAt? += stood
                restoreStartedAt += stood
            }
        }
        pausedAt = nil
        mixer.resumeAll()
    }


    public func stop() {
        mixer.stopDeck(.a)
        mixer.stopDeck(.b)
        phase = .idle
        mix = nil
        current = nil
        restoreEndsAt = nil
    }

    /// Moves the record playing, abandoning any mix booked against where it was.
    public func seek(to seconds: Double, at sessionSeconds: Double) throws {
        guard let current else { return }
        mixer.stopDeck(other)
        mixer.clearEcho(side)
        mix = nil
        try mixer.load(current.url, on: side, from: seconds)
        mixer.play(side)
        startedAt = sessionSeconds
        startOffset = seconds
        phase = .playing
    }
}
