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

    public init(url: URL, sound: SilenceBounds? = nil, gainDb: Double? = nil, grid: BeatGrid? = nil) {
        self.url = url
        self.sound = sound
        self.gainDb = gainDb
        self.grid = grid
    }

    var startSeconds: Double { (sound?.soundStart.seconds).map { max(0, $0) } ?? 0 }
    var endSeconds: Double? { sound?.soundEnd.seconds }
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

    /// How far through a mix the decks are, 0…1, or nothing if none is running.
    /// A screen can draw a crossfader with this.
    public func mixProgress(at sessionSeconds: Double) -> Double? {
        guard let mix, sessionSeconds >= mix.startsAt else { return nil }
        return min(1, max(0, (sessionSeconds - mix.startsAt) / mix.transition.seconds))
    }

    public private(set) var phase: Phase = .idle

    /// The session clock, in seconds, at which the record now playing began.
    private var startedAt: Double = 0
    /// Where in that record playback began.
    private var startOffset: Double = 0
    private var current: DJItem?

    private struct Mix {
        let transition: DJTransition
        let incoming: DJItem
        /// Session time the two decks begin running together.
        let startsAt: Double
        /// Where the incoming record was started from.
        let incomingOffset: Double
    }

    private var mix: Mix?
    /// The session time at which the bend must be finished being eased out.
    private var restoreEndsAt: Double?

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
    public func start(
        _ item: DJItem,
        from seconds: Double,
        at sessionSeconds: Double,
        inSeconds lead: Double = 0
    ) throws {
        try mixer.load(item.url, on: side, from: seconds)
        mixer.setVolume(lead > 0 ? 0 : item.linearGain, on: side)
        mixer.setBassDb(0, on: side)
        mixer.setRate(1, on: side)
        if lead > 0 {
            mixer.play(side, inSeconds: lead)
        } else {
            mixer.play(side)
        }
        current = item
        startedAt = sessionSeconds + lead
        startOffset = seconds
        phase = .playing
        mix = nil
    }

    /// Scales the playing deck against the record's own levelling, for a fade
    /// that belongs to something other than a mix.
    public func setCurrentVolume(scale: Double) {
        mixer.setVolume((current?.linearGain ?? 1) * max(0, min(1, scale)), on: side)
    }

    /// Where the record playing has got to, in its own timeline.
    public func position(at sessionSeconds: Double) -> Double {
        startOffset + max(0, sessionSeconds - startedAt) * mixer.rate(on: side)
    }

    /// Plans nothing and decides nothing: takes a transition somebody else
    /// planned and books the incoming record onto the other deck for it.
    ///
    /// The booking is the part that has to be exact, and it is done once, here,
    /// against the mixer's own clock — after this the two decks are running and
    /// nothing that happens on the main thread can pull them apart.
    public func schedule(_ transition: DJTransition, into incoming: DJItem, at sessionSeconds: Double) throws {
        guard phase == .playing else { return }
        let position = position(at: sessionSeconds)
        let untilMix = (transition.outgoingStartMs / 1000 - position) / mixer.rate(on: side)
        guard untilMix > 0 else { return }

        let incomingOffset = transition.incomingStartMs / 1000
        try mixer.load(incoming.url, on: other, from: incomingOffset)
        // The state the deck must be in for its first instant, before any
        // automation has run: silent, and with the low end already out of the
        // way. `update` overwrites both a tick later, so this only governs the
        // moment between the deck starting and the first tick after it — which
        // is exactly the moment a record would otherwise arrive at full volume.
        mixer.setVolume(0, on: other)
        mixer.setBassDb(DJAutomation.bassCutDb, on: other)
        mixer.setRate(transition.incomingRate, on: other)
        mixer.play(other, inSeconds: untilMix)

        mix = Mix(
            transition: transition,
            incoming: incoming,
            startsAt: sessionSeconds + untilMix,
            incomingOffset: incomingOffset
        )
    }

    /// Runs the automation. Call as often as convenient; missing a call makes the
    /// fade coarser and nothing else.
    public func update(at sessionSeconds: Double) {
        easeRateBack(at: sessionSeconds)

        guard let mix else {
            endTrackIfFinished(at: sessionSeconds)
            return
        }
        guard sessionSeconds >= mix.startsAt else { return }

        let progress = (sessionSeconds - mix.startsAt) / mix.transition.seconds
        if progress >= 1 {
            finish(mix, at: sessionSeconds)
            return
        }

        phase = .mixing
        mixer.apply(progress: progress, outgoing: side, incoming: other, transition: mix.transition)
        // The levelling sits underneath the mix's own curve, so two records that
        // were brought to one loudness stay there while they cross.
        mixer.setVolume(DJAutomation.outgoingGain(progress: progress) * (current?.linearGain ?? 1), on: side)
        mixer.setVolume(DJAutomation.incomingGain(progress: progress) * mix.incoming.linearGain, on: other)
    }

    /// The mix is over: the outgoing deck is silent and is stopped, and the
    /// record that came in is simply the record playing.
    private func finish(_ mix: Mix, at sessionSeconds: Double) {
        mixer.setVolume(0, on: side)
        mixer.stopDeck(side)
        mixer.setBassDb(0, on: other)
        mixer.setVolume(mix.incoming.linearGain, on: other)

        side = other
        current = mix.incoming
        startOffset = mix.incomingOffset
        // The incoming deck has been running since the mix began, at its bent
        // rate, so its clock did not start now — it started then.
        startedAt = mix.startsAt
        phase = .playing
        self.mix = nil

        // Bent to meet the record that has just ended; it gets its own tempo back
        // over the next few seconds rather than keeping somebody else's forever.
        if mix.transition.incomingRate != 1 {
            restoreEndsAt = sessionSeconds + mix.transition.restoreSeconds
            restoreFrom = mix.transition.incomingRate
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
            mixer.setRate(1, on: side)
            restoreEndsAt = nil
            return
        }
        let progress = (sessionSeconds - restoreStartedAt) / (ends - restoreStartedAt)
        mixer.setRate(restoreFrom + (1 - restoreFrom) * progress, on: side)
    }

    private func endTrackIfFinished(at sessionSeconds: Double) {
        guard phase == .playing, let current, let end = current.endSeconds else { return }
        guard position(at: sessionSeconds) >= end else { return }
        phase = .idle
        mixer.stopDeck(side)
        onTrackEnded?()
    }

    // MARK: - Transport

    public func pause() { mixer.pauseAll() }
    public func resume() { mixer.resumeAll() }

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
        mix = nil
        try mixer.load(current.url, on: side, from: seconds)
        mixer.play(side)
        startedAt = sessionSeconds
        startOffset = seconds
        phase = .playing
    }
}
