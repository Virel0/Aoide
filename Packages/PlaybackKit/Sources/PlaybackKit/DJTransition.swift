import Foundation

/// A mix: two records beat-matched, bar-aligned and handed over on a downbeat.
///
/// The thing [Crossfade](../../../../docs/crossfade.md) is not. A crossfade is a
/// volume fade between two songs that happen to be next to each other; this puts
/// both decks on one tempo, lines their bars up, and swaps the bass over halfway
/// through — which is what makes a mix sound like one piece of music rather than
/// two overlapping.
///
/// Everything here is arithmetic over the sidecar's
/// [beat grid](../../../../docs/beat-grid.md). No audio, so the rules can be
/// argued with directly.
///
/// **It refuses far more often than it fires**, and that is the design rather
/// than a limitation. Anything without a grid, a meter, mix points, a tempo
/// close enough to bend, or room to run — falls back to Crossfade, which is
/// already built and already good. Apple's own AutoMix does the same: it mixes
/// when it can and crossfades when it cannot.
public struct DJTransition: Equatable, Sendable {
    /// Where the mix begins in the outgoing track, on its own clock. A downbeat.
    public let outgoingStartMs: Double
    /// Where the incoming track begins playing. Its mix-in downbeat.
    public let incomingStartMs: Double
    /// How many bars the two run together.
    public let bars: Int
    /// How long that is in seconds, at the tempo the mix runs at.
    public let seconds: Double
    /// The tempo both decks run at while they are together.
    public let targetBpm: Double
    /// What the outgoing deck's playback rate is set to. Always 1: the record
    /// already playing is the one the listener is already hearing, and bending it
    /// under them is the one thing a mix must not do.
    public let outgoingRate: Double
    /// What the incoming deck runs at to meet it — the bend, and it is always
    /// this deck that bends.
    public let incomingRate: Double
    /// How long, after the mix, the incoming track takes to ease back to its own
    /// tempo. Left bent forever, every record after the first would play at the
    /// speed of whatever preceded it.
    public let restoreSeconds: Double
    /// Whether the two keys are neighbours on the Camelot wheel. Never a reason
    /// to refuse a mix — the key estimator is weakest exactly where a listener
    /// would not have minded — but worth knowing, and worth preferring on when
    /// something upstream is choosing which record comes next.
    public let isKeyCompatible: Bool
}

public enum DJPlanner {
    /// What a mix wants to be: sixteen bars, the length a DJ reaches for.
    public static let preferredBars = 16
    /// And what it will settle for when there is not room for sixteen.
    public static let minimumBars = 8

    /// How far a record may be bent to meet another.
    ///
    /// Six per cent is about the range of a turntable's pitch fader, and it is
    /// also about where a listener starts to hear that something has been done
    /// to the record rather than to the mix.
    public static let maximumStretch = 0.06

    /// How long the incoming record takes to find its own tempo again once the
    /// mix is over. Long enough not to be a lurch, short enough to be finished
    /// before anybody is listening for it.
    public static let restoreSeconds = 8.0

    /// Plans a mix, or returns nothing — which means Crossfade.
    ///
    /// - Parameters:
    ///   - outgoing: the grid of the record playing now.
    ///   - incoming: the grid of the one that follows.
    ///   - notBeforeMs: the earliest point in the outgoing track the mix may
    ///     start. The engine's answer to "how much warning do I need", which is
    ///     however long it takes to have the next file open and ready.
    public static func plan(
        outgoing: BeatGrid,
        incoming: BeatGrid,
        notBeforeMs: Double = 0,
        outgoingArrangement: Arrangement? = nil,
        incomingArrangement: Arrangement? = nil
    ) -> DJTransition? {
        // Both records have to be gridded, metered, and have somewhere to mix.
        guard let outMixOut = outgoing.mixOutMs,
              let inMixIn = incoming.mixInMs,
              let outSegment = outgoing.segment(at: outMixOut),
              let inSegment = incoming.segment(at: inMixIn),
              outgoing.beatsPerBar != nil,
              incoming.beatsPerBar != nil,
              let outBar = outgoing.barMs(at: outMixOut),
              let inBar = incoming.barMs(at: inMixIn)
        else { return nil }

        // The bend, folded into one octave: 85 against 170 is one groove counted
        // two ways, and the incoming deck can play the double-time record at half
        // speed to sit inside it.
        guard let rate = bendableRate(from: inSegment.bpm, to: outSegment.bpm) else { return nil }

        // Sixteen bars if they fit, eight if only those do. Measured against the
        // outgoing record, which is the one with a deadline.
        //
        // Records whose keys clash get the short mix even when there is room for
        // the long one. Sixteen bars is half a minute of two keys arguing, and
        // the complaint that produced this rule was two tracks seven steps apart
        // on the wheel held against each other for thirty seconds. It is still
        // never a *refusal* — the key estimator has not been tried on real music,
        // and refusing on a guess is worse than a short mix.
        let clashes = outgoing.key != nil && incoming.key != nil
            && !CamelotKey.areCompatible(outgoing.key, incoming.key)

        // Where the incoming record comes in: its mix-in point, moved back onto
        // the start of the phrase it sits in when the record counts phrases. A
        // mix is counted in phrases, and a record brought in three bars into one
        // is a record brought in at the wrong moment however exactly its beats
        // land.
        let entry = incomingArrangement?.phraseStart(atOrBefore: inMixIn, barMs: inBar)
            ?? incoming.downbeat(atOrBefore: inMixIn)
            ?? inMixIn

        // Two drops on top of each other is the mistake every DJ names first —
        // a new chorus dropped onto somebody else's. Nothing here can find a
        // better place to come in, but it can decline to sit there for long.
        let dropOnDrop = outgoingArrangement?.section(at: outMixOut)?.kind == .drop
            && incomingArrangement?.section(at: entry)?.kind == .drop

        let lengths = clashes || dropOnDrop ? [minimumBars] : [preferredBars, minimumBars]

        for bars in lengths {
            let seconds = outBar * Double(bars) / 1000
            // Back from the mix-out point a whole number of bars, then onto the
            // phrase line if the record has them. The mix may end a little before
            // the mix-out point as a result; it will not start mid-phrase.
            let counted = outMixOut - outBar * Double(bars)
            let startMs = outgoingArrangement?.phraseStart(atOrBefore: counted, barMs: outBar) ?? counted

            guard startMs >= notBeforeMs else { continue }

            // Two records singing at once is the other thing on every list of
            // what not to do, and not something a client can hear for itself.
            // Unknown counts as singing: a false positive costs a mix, and a
            // false negative is the exact mistake this exists to prevent.
            if let outgoingArrangement, let incomingArrangement {
                let outgoingSings = outgoingArrangement.maySing(from: startMs, to: startMs + seconds * 1000)
                let incomingSings = incomingArrangement.maySing(from: entry, to: entry + seconds * 1000 * rate)
                if outgoingSings && incomingSings { continue }
            }
            // The whole mix has to sit inside one tempo on both sides: a segment
            // boundary is a tempo change, and a grid fitted either side of one
            // describes neither half of what is playing.
            guard outgoing.canLock(at: startMs, blendSeconds: seconds) else { continue }
            guard incoming.canLock(at: entry, blendSeconds: seconds) else { continue }
            // And the incoming record must have that much of itself to give.
            // Measured in its own timeline, which a bend consumes faster or
            // slower than the clock: thirty seconds at 1.05 eats thirty-one and
            // a half seconds of record.
            let incomingNeeded = seconds * 1000 * rate
            guard entry + incomingNeeded <= inSegment.endMs else { continue }

            // The outgoing side snapped to the grid rather than trusted. The
            // contract says `mixOutMs` is a downbeat and the sidecar keeps that
            // promise — but the arithmetic inherits whatever phase it carries,
            // so a mix point half a beat out would produce a mix half a beat out,
            // silently and for every pair. Snapping costs a bar at most and makes
            // the alignment true of the grid rather than of the promise. (The
            // incoming side was snapped when `entry` was chosen.)
            let start = outgoing.downbeat(atOrBefore: startMs) ?? startMs

            return DJTransition(
                outgoingStartMs: start,
                incomingStartMs: entry,
                bars: bars,
                seconds: seconds,
                targetBpm: outSegment.bpm,
                outgoingRate: 1,
                incomingRate: rate,
                restoreSeconds: restoreSeconds,
                isKeyCompatible: CamelotKey.areCompatible(outgoing.key, incoming.key)
            )
        }
        return nil
    }

    /// The rate the incoming deck runs at to sit on the outgoing tempo, or
    /// nothing if that is further than a record may be bent.
    ///
    /// Folded into one octave first, because 85 against 170 is one groove
    /// counted two ways — and note what that means for the rate it returns: a
    /// double-time record is **not** slowed to half speed. It is played at its
    /// own speed, where its beats already coincide with every other beat of the
    /// other record, which is what a DJ mixing drum and bass over hip-hop is
    /// doing.
    static func bendableRate(from bpm: Double, to target: Double) -> Double? {
        guard bpm > 0, target > 0, bpm.isFinite, target.isFinite else { return nil }
        var ratio = target / bpm
        while ratio > 1.5 { ratio /= 2 }
        while ratio < 1 / 1.5 { ratio *= 2 }
        // A hair of slack, because the limit is a musical judgement rather than
        // an exact quantity and 128 × 1.06 does not divide back to exactly 1.06.
        guard abs(ratio - 1) <= maximumStretch + 1e-9 else { return nil }
        return ratio
    }
}

/// What each deck does across the length of a mix, as numbers an engine applies.
///
/// Rewritten after a rendered mix measured **four and a half decibels down at
/// the swap**, which a listener heard as the volume dropping and having to be
/// turned back up. Two records crossing should sound like one record playing.
///
/// **The defect was the bass swap, and only the bass swap.** Two shelves meeting
/// at half their travel are each down twelve decibels, and twelve down on both
/// records at once is a hole in the low end — where most of the energy in this
/// kind of music is. They are complementary in *power* now: at the crossing each
/// sits at −3 dB, so the two together are one record's worth of bass throughout.
/// Re-measured, the notch is gone.
///
/// **The faders are a separate judgement, and a smaller one.** They barely move
/// now — a DJ mixing on EQ does not ride the crossfader, and the record holding
/// the low end is the record in front, so turning it down before it hands the
/// bass over is turning the mix down. Measurement puts that change at about a
/// decibel either way; it is here because it is how the thing is done, not
/// because it was what was wrong.
public enum DJAutomation {
    /// Where the bass hands over: the middle of the mix, which is a downbeat
    /// because the mix is a whole number of bars.
    public static let swapPoint = 0.5

    /// How much of the mix the swap takes — about a bar.
    ///
    /// Not shorter: the gain of a shelf has to be stepped by something, and
    /// stepping twenty-four decibels in two ticks is a click. Not longer: while
    /// it happens both records have some low end, and that is the mud the swap
    /// exists to avoid.
    public static let swapWidth = 0.08

    /// How far the low end is taken down. Not silence: a shelf this deep is
    /// inaudible under the other record's bass, and going to zero makes the
    /// return audible as a hole closing.
    public static let bassCutDb = -24.0

    /// The incoming record is up to full within about a bar, and stays there.
    public static let entryWidth = 0.1

    /// The outgoing record holds its level until the bass leaves it, then goes.
    /// Before that point it is the record carrying the low end, and turning it
    /// down is turning the mix down.
    public static func outgoingGain(progress: Double) -> Double {
        let progress = clamp(progress)
        guard progress > swapPoint else { return 1 }
        return MixCurve.outgoing(progress: (progress - swapPoint) / (1 - swapPoint))
    }

    public static func incomingGain(progress: Double) -> Double {
        let progress = clamp(progress)
        guard progress < entryWidth else { return 1 }
        return MixCurve.incoming(progress: progress / entryWidth)
    }

    /// The outgoing record keeps its bass until the swap, then loses it.
    public static func outgoingBassDb(progress: Double) -> Double {
        db(MixCurve.outgoing(progress: ramp(progress)))
    }

    /// And the incoming record has none until the swap, then takes it.
    public static func incomingBassDb(progress: Double) -> Double {
        db(MixCurve.incoming(progress: ramp(progress)))
    }

    /// A linear gain as decibels on the shelf, floored at the cut rather than
    /// running away to silence.
    private static func db(_ gain: Double) -> Double {
        guard gain > 0 else { return bassCutDb }
        return max(bassCutDb, 20 * log10(gain))
    }

    /// 0 before the swap, 1 after it, and a short straight line between.
    static func ramp(_ progress: Double) -> Double {
        let start = swapPoint - swapWidth / 2
        return clamp((clamp(progress) - start) / swapWidth)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
