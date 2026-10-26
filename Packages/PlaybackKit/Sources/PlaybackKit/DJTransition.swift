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
    /// How the pair scored, and why. See ``MixScore``.
    public let score: MixScore
    /// How the outgoing record leaves.
    public let style: Style

    /// Two ways out.
    public enum Style: Equatable, Sendable {
        /// The standard blend: the outgoing record keeps its whole voice until
        /// the swap, gives up its bass, and fades. For pairs that agree.
        case blend
        /// The filter fade: the outgoing record's low end *and* its middle are
        /// swept away across the first half — melody, chords and the body of a
        /// voice go, hats and snare stay — so by the time the incoming record
        /// has its bass, the old one is rhythm and air. For pairs that clash in
        /// key, or where one of them is singing: the two never have their notes
        /// on top of each other, which is the whole point of it.
        case filterFade
        /// No overlap at all: the outgoing record stops on a phrase line and
        /// the incoming one starts on its own, that instant. For a pair whose
        /// tempi are too far apart to bend, or that both sing — a jolt, on the
        /// beat, rather than a blend that was never going to work.
        case cut
        /// A cut, with the outgoing record's last beat left ringing in a
        /// delay under the first bar of the new one. What a DJ reaches for
        /// when the tempos will not live together and the room should not
        /// hear a wall: the old record ends *into* the new one.
        case echoOut

        /// Whether the two records overlap at all.
        public var overlaps: Bool {
            switch self {
            case .blend, .filterFade: true
            case .cut, .echoOut: false
            }
        }
    }
}

public enum DJPlanner {
    /// What a pair with nothing known against it gets: sixteen bars.
    public static let preferredBars = 16
    /// The shortest a mix is; anything less is a crossfade.
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

    /// The longest a pair may run together, and the lengths tried in turn.
    public static let lengths = [32, 16, 8]

    /// Plans a mix, or returns nothing — which means Crossfade.
    ///
    /// - Parameters:
    ///   - outgoing: the grid of the record playing now.
    ///   - incoming: the grid of the one that follows.
    ///   - notBeforeMs: the earliest point in the outgoing track the mix may
    ///     start. The engine's answer to "how much warning do I need", which is
    ///     however long it takes to have the next file open and ready.
    ///   - outgoingArrangement, incomingArrangement: what each record is made of,
    ///     when the server has measured it. Without them the pair is scored on
    ///     tempo and key alone and comes in at its mix-in point.
    public static func plan(
        outgoing: BeatGrid,
        incoming: BeatGrid,
        notBeforeMs: Double = 0,
        outgoingArrangement: Arrangement? = nil,
        incomingArrangement: Arrangement? = nil,
        outgoingExitMs: Double? = nil
    ) -> DJTransition? {
        plan(
            outgoing: outgoing, incoming: incoming, notBeforeMs: notBeforeMs,
            outgoingArrangement: outgoingArrangement, incomingArrangement: incomingArrangement,
            outgoingExitsMs: outgoingExitMs.map { [$0] } ?? []
        )
    }

    /// How much better a mix from a later or earlier exit has to score than
    /// the mix from the set's own first choice before it is taken instead.
    /// The set's choice is where the room has had the hook and no more; a
    /// different exit means more or less of the record, and that is only
    /// worth it when the join is clearly better, not marginally.
    public static let exitPreferenceMargin = 0.1

    /// The same, from a list of places the outgoing record could leave, best
    /// first — every end of a hook the set would accept. Each is tried
    /// against every entry of the incoming record, and the first exit's best
    /// stands unless another exit beats it by ``exitPreferenceMargin``. The
    /// exit and the entry are chosen *for the pair*: where this record leaves
    /// depends on what is coming, and where that comes in on where this one
    /// leaves.
    public static func plan(
        outgoing: BeatGrid,
        incoming: BeatGrid,
        notBeforeMs: Double = 0,
        outgoingArrangement: Arrangement? = nil,
        incomingArrangement: Arrangement? = nil,
        outgoingExitsMs: [Double]
    ) -> DJTransition? {
        let exits = outgoingExitsMs.isEmpty ? [outgoing.mixOutMs].compactMap { $0 } : outgoingExitsMs
        var preferred: DJTransition?
        var best: DJTransition?
        for (index, exit) in exits.enumerated() {
            guard let candidate = plan(
                outgoing: outgoing, incoming: incoming, notBeforeMs: notBeforeMs,
                outgoingArrangement: outgoingArrangement, incomingArrangement: incomingArrangement,
                exitMs: exit
            ) else { continue }
            if index == 0 { preferred = candidate }
            if best.map({ candidate.score.total > $0.score.total }) ?? true { best = candidate }
        }
        guard let best else { return nil }
        guard let preferred else { return best }
        return best.score.total - preferred.score.total >= exitPreferenceMargin ? best : preferred
    }

    /// One exit, every entry.
    private static func plan(
        outgoing: BeatGrid,
        incoming: BeatGrid,
        notBeforeMs: Double,
        outgoingArrangement: Arrangement?,
        incomingArrangement: Arrangement?,
        exitMs: Double
    ) -> DJTransition? {
        // Both records have to be gridded, metered, and have somewhere to mix —
        // and both have to have been *read*. Matching tempo is not a substitute
        // for knowing the arrangement: without it, two pop records with clashing
        // keys and a voice on each were scoring eight bars together, and eight
        // bars of two singers in two keys is not a mix by any definition. A
        // record the server has not read yet crossfades, which is fine.
        guard outgoingArrangement != nil, incomingArrangement != nil else { return nil }
        let outMixOut = exitMs
        guard let inMixIn = incoming.mixInMs,
              let outSegment = outgoing.segment(at: outMixOut),
              outgoing.beatsPerBar != nil,
              incoming.beatsPerBar != nil,
              let outBar = outgoing.barMs(at: outMixOut),
              let inBar = incoming.barMs(at: inMixIn)
        else { return nil }

        // The bend, folded into one octave: 85 against 170 is one groove counted
        // two ways, and the incoming deck can play the double-time record at half
        // speed to sit inside it.
        guard let rate = bendableRate(from: incoming.segment(at: inMixIn)?.bpm ?? 0, to: outSegment.bpm) else { return nil }

        // Where the incoming record could come in. Its mix-in point always; and
        // with an arrangement, the start of every build, intro and breakdown as
        // well — because coming in on a build is what a DJ does, and the mix-in
        // point is only where the groove starts.
        var entries = [entryPoint(inMixIn, in: incoming, arrangement: incomingArrangement, barMs: inBar)]
        for section in incomingArrangement?.sections ?? [] where [.build, .intro, .breakdown].contains(section.kind) {
            entries.append(entryPoint(section.startMs, in: incoming, arrangement: incomingArrangement, barMs: inBar))
        }

        // Best score wins; on a tie, the earlier entry, which is the thinner one.
        var best: DJTransition?
        for entry in Set(entries).sorted() {
            guard let candidate = plan(
                entry: entry, rate: rate,
                outgoing: outgoing, incoming: incoming,
                outMixOut: outMixOut, outBar: outBar, inBar: inBar, outSegmentBpm: outSegment.bpm,
                notBeforeMs: notBeforeMs,
                outgoingArrangement: outgoingArrangement, incomingArrangement: incomingArrangement
            ) else { continue }
            if best.map({ candidate.score.total > $0.score.total }) ?? true {
                best = candidate
            }
        }
        return best
    }

    /// How long the last beat rings after an echo-out: two bars of the
    /// outgoing tempo, under the first two of the new record.
    ///
    /// Two seconds was too short — one repeat, then the new record, which is
    /// a cut with a hiccup rather than a tail. A DJ lets the echo run for a
    /// bar or two and lets the feedback do the fading.
    public static let echoTailBars = 2.0

    /// The tail in seconds, at the tempo the echo repeats at.
    public static func echoTailSeconds(targetBpm: Double) -> Double {
        guard targetBpm > 0 else { return 0 }
        return echoTailBars * 4 * 60 / targetBpm
    }

    /// Where along the tail the fader starts to close. Until then the repeats
    /// decay on the feedback alone, which is the sound of an echo-out; the
    /// fader only sees the last of them out so the ring does not stop dead.
    public static let echoFadeFrom = 0.6

    /// How long after the outgoing record is cut the incoming one comes in:
    /// two beats of the outgoing tempo. The tail is a bridge, not a backdrop —
    /// the room hears the record stop, its last hit repeat across two beats
    /// of nothing else, and the new record land while the repeats are still
    /// going. Starting the new record on the cut itself buried the tail under
    /// it; a whole bar's gap let the tail finish first, and the new record
    /// arrived after a silence. Two beats is where the repeats are still
    /// audible under the new record's first bar.
    public static let echoGapBeats = 2.0

    public static func echoGapSeconds(targetBpm: Double) -> Double {
        guard targetBpm > 0 else { return 0 }
        return echoGapBeats * 60 / targetBpm
    }

    /// How long before the cut the echo is brought in under the record: two
    /// beats. The record does not stop and *then* start repeating — the
    /// repeats build under its last two beats as the dry signal goes, so by
    /// the phrase line there is nothing left to stop. A record that stopped
    /// dead on the line and then echoed sounded like a fault followed by an
    /// effect, which is what it was.
    public static let echoLeadBeats = 2.0

    public static func echoLeadSeconds(targetBpm: Double) -> Double {
        guard targetBpm > 0 else { return 0 }
        return echoLeadBeats * 60 / targetBpm
    }

    /// Where the tail's high-pass corner ends up, and the low end with it:
    /// swept there across the *approach*, so the bass is gone before the echo
    /// engages — a delayed kick under a new kick is the first thing that
    /// sounds clunky about an echo-out, and a kick already in the delay when
    /// the cut falls rings for two bars whatever the filter does afterwards.
    public static let echoHighPassHz = 200.0

    /// How loud the ring is against the word it repeats. A first repeat as
    /// loud as the word reads as a glitch; one a few decibels under it reads
    /// as an echo. Each repeat after it is the feedback's.
    public static let echoRingLevel = 0.6

    /// Where a filtered cut's low-pass ends up, and the top with it, across
    /// the last two beats before the line: the record rolls off and stops,
    /// and the new one comes in dry on the line. The exit for a pair that
    /// cannot be mixed when there is no clean word to throw — a smeared
    /// syllable repeated four times is worse than no echo.
    public static let filteredCutHz = 300.0

    /// Plans a cut — or an echo-out — for a pair that has been read but cannot
    /// be mixed: tempi too far apart to bend, or both records singing. The
    /// outgoing record stops on the phrase line at its exit; the incoming one
    /// starts, that instant, on the phrase line at its entry.
    ///
    /// Nothing for a pair that has not been read, which crossfades instead — a
    /// cut is a decision about two records, and a decision needs to know them.
    public static func planCut(
        outgoing: BeatGrid,
        incoming: BeatGrid,
        notBeforeMs: Double = 0,
        outgoingArrangement: Arrangement?,
        incomingArrangement: Arrangement?,
        outgoingExitMs: Double? = nil,
        outgoingLyricLinesMs: [Double]? = nil,
        incomingLyricLinesMs: [Double]? = nil
    ) -> DJTransition? {
        guard let outgoingArrangement, let incomingArrangement else { return nil }
        guard let outMixOut = outgoingExitMs ?? outgoing.mixOutMs,
              let inMixIn = incoming.mixInMs,
              let outSegment = outgoing.segment(at: outMixOut),
              outgoing.beatsPerBar != nil, incoming.beatsPerBar != nil,
              let outBar = outgoing.barMs(at: outMixOut),
              let inBar = incoming.barMs(at: inMixIn)
        else { return nil }

        // A cut stops the record dead, so the line has to be one nobody is
        // singing across — a mix fades the outgoing voice under the new
        // record and can afford a line mid-word; a cut cannot.
        let judged = outgoingArrangement.cleanLineJudged(atOrBefore: outMixOut, barMs: outBar, lyricLinesMs: outgoingLyricLinesMs) { outgoing.downbeat(atOrBefore: $0) }
        let exit = judged?.ms ?? outMixOut
        guard exit >= notBeforeMs else { return nil }
        // The new record lands on its first line when that is near its
        // start — the moment a listener knows the record — and on its mix-in
        // point otherwise.
        let entry = Arrangement.landmarkMs(lyricLinesMs: incomingLyricLinesMs, mixInMs: inMixIn, barMs: inBar) { incoming.downbeat(atOrBefore: $0) }
            ?? entryPoint(inMixIn, in: incoming, arrangement: incomingArrangement, barMs: inBar)

        // An echo-out repeats whatever the last beat held, so with lyrics to
        // read it is only planned when that is a finished thing — a line's
        // last word, with the next line starting on the beat after the cut,
        // or a rest. When the lyrics say every line in reach is mid-line the
        // pair is cut with the top rolled off over the last two beats
        // instead: a smeared syllable repeated four times is worse than no
        // echo. Without lyrics the throw stands: the vocal spans place the
        // line as well as they can, but they are blocks of "somebody is
        // singing", too coarse to refuse on — every pop hook read as sung
        // throughout, and a set that filtered-cut every pair was a set with
        // no echo in it at all.
        let style: DJTransition.Style = outgoingLyricLinesMs == nil || (judged?.clean ?? false) ? .echoOut : .cut
        let exitEnergy = outgoingArrangement.section(at: exit)?.energy
        let entryEnergy = incomingArrangement.section(at: entry)?.energy

        let rate = bendableRate(from: incoming.segment(at: entry)?.bpm ?? 0, to: outSegment.bpm) ?? 1
        return DJTransition(
            outgoingStartMs: exit,
            incomingStartMs: entry,
            bars: 0,
            seconds: 0,
            targetBpm: outSegment.bpm,
            outgoingRate: 1,
            // A record that cannot be bent is played at its own speed; one
            // that could be is not, since nothing is running alongside it.
            incomingRate: 1,
            restoreSeconds: 0,
            isKeyCompatible: CamelotKey.areCompatible(outgoing.key, incoming.key),
            score: MixScore(
                tempo: MixScore.tempo(rate: rate),
                key: MixScore.key(outgoing.key, incoming.key),
                vocals: 0.5, energy: MixScore.energy(exitEnergy, entryEnergy),
                sections: MixScore.sections(
                    exit: outgoingArrangement.section(at: exit)?.kind,
                    entry: incomingArrangement.section(at: entry)?.kind
                )
            ),
            style: style
        )
    }

    /// A candidate entry, put on the phrase line it sits in when the record
    /// counts phrases and on the bar line otherwise. A record brought in three
    /// bars into a phrase is a record brought in at the wrong moment however
    /// exactly its beats land.
    private static func entryPoint(_ ms: Double, in grid: BeatGrid, arrangement: Arrangement?, barMs: Double) -> Double {
        arrangement?.phraseLine(near: ms, barMs: barMs)
            ?? grid.downbeat(atOrBefore: ms)
            ?? ms
    }

    /// One entry point, scored and fitted.
    private static func plan(
        entry: Double,
        rate: Double,
        outgoing: BeatGrid,
        incoming: BeatGrid,
        outMixOut: Double,
        outBar: Double,
        inBar: Double,
        outSegmentBpm: Double,
        notBeforeMs: Double,
        outgoingArrangement: Arrangement?,
        incomingArrangement: Arrangement?
    ) -> DJTransition? {
        guard let inSegment = incoming.segment(at: entry) else { return nil }

        let exitKind = outgoingArrangement?.section(at: outMixOut)?.kind
        let entryKind = incomingArrangement?.section(at: entry)?.kind

        // Two drops on top of each other is the mistake every DJ names first —
        // a new chorus dropped onto somebody else's. Whatever the rest of the
        // score says, that pair does not get long together. Nor do two records
        // whose keys are known to clash: the filter fade takes the melody out of
        // the outgoing one, but progressively, and the shorter the overlap the
        // less of it there is to hear.
        let dropOnDrop = exitKind == .drop && entryKind == .drop
        let keysClash = outgoing.key != nil && incoming.key != nil
            && !CamelotKey.areCompatible(outgoing.key, incoming.key)
        let capped = dropOnDrop || keysClash
        // And a filter fade — which is what a pair with a voice on either
        // side gets — is capped too: the filter takes the melody out of the
        // outgoing record progressively, and thirty-two bars of a voice being
        // slowly filtered under another record is thirty-two bars of clash.
        // Eight is long enough for the sweep to read as a move.

        for bars in lengths {
            let seconds = outBar * Double(bars) / 1000
            // Back from the mix-out point a whole number of bars, then onto the
            // phrase line if one is close, else the bar line. The mix may end a
            // little before the mix-out point as a result — never seven bars
            // before it, which would fade the hook out under the new record.
            let counted = outMixOut - outBar * Double(bars)
            let startMs = outgoingArrangement?.phraseLine(atOrBefore: counted, barMs: outBar)
                ?? outgoing.downbeat(atOrBefore: counted)
                ?? counted

            guard startMs >= notBeforeMs else { continue }
            guard outgoing.canLock(at: startMs, blendSeconds: seconds) else { continue }
            guard incoming.canLock(at: entry, blendSeconds: seconds) else { continue }
            // A bent record is eaten faster than the clock — thirty seconds at
            // 1.05 is thirty-one and a half of source — so it has to have that
            // much of itself left rather than that much wall time.
            guard entry + seconds * 1000 * rate <= inSegment.endMs else { continue }

            // Singing, across exactly the stretch that would overlap.
            let outgoingSings = outgoingArrangement.map { $0.maySing(from: startMs, to: startMs + seconds * 1000) }
            let incomingSings = incomingArrangement.map { $0.maySing(from: entry, to: entry + seconds * 1000 * rate) }
            // Two records singing at once is the other thing on every list of
            // what not to do, and not something a client can hear for itself.
            // Unknown counts as singing: a false positive costs a mix, and a
            // false negative is the exact mistake this exists to prevent.
            if outgoingSings == true && incomingSings == true { continue }

            let score = MixScore(
                tempo: MixScore.tempo(rate: rate),
                key: MixScore.key(outgoing.key, incoming.key),
                vocals: MixScore.vocals(outgoingSings: outgoingSings, incomingSings: incomingSings),
                energy: MixScore.energy(
                    outgoingArrangement?.section(at: startMs)?.energy,
                    incomingArrangement?.section(at: entry)?.energy
                ),
                sections: MixScore.sections(exit: exitKind, entry: entryKind)
            )
            guard let earned = score.bars else { return nil }
            let allowed = capped ? min(earned, minimumBars) : earned
            guard bars <= allowed else { continue }

            // The outgoing side snapped to the grid rather than trusted. The
            // contract says `mixOutMs` is a downbeat and the sidecar keeps that
            // promise — but the arithmetic inherits whatever phase it carries,
            // so a mix point half a beat out would produce a mix half a beat out,
            // silently and for every pair. Snapping costs a bar at most and makes
            // the alignment true of the grid rather than of the promise. (The
            // incoming side was snapped when `entry` was chosen.)
            let start = outgoing.downbeat(atOrBefore: startMs) ?? startMs

            // Something to hide — a key that is *known* to clash, or one record
            // singing — gets the filter fade. Nothing to hide gets the blend. A
            // key nobody measured is not a clash; most of a library has none.
            let compatible = CamelotKey.areCompatible(outgoing.key, incoming.key)
            let clashes = outgoing.key != nil && incoming.key != nil && !compatible
            let anyoneSings = outgoingSings == true || incomingSings == true
            let style: DJTransition.Style = (clashes || anyoneSings) ? .filterFade : .blend
            guard style == .blend || bars <= minimumBars else { continue }

            return DJTransition(
                outgoingStartMs: start,
                incomingStartMs: entry,
                bars: bars,
                seconds: seconds,
                targetBpm: outSegmentBpm,
                outgoingRate: 1,
                incomingRate: rate,
                restoreSeconds: restoreSeconds,
                isKeyCompatible: compatible,
                score: score,
                style: style
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

    /// The incoming record comes up over the first half of the mix — eight bars
    /// of a sixteen-bar one — and holds there.
    ///
    /// It used to arrive within a bar, which is a fader shoved rather than
    /// raised. A DJ brings the drums and the top of the new record in over
    /// eight to sixteen bars *under* the old one, and the swap is the first
    /// moment the room is meant to notice; the bass arrives at the swap point
    /// whatever this says, so this only governs how the hats and the air get
    /// there.
    public static let entryWidth = 0.5

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

    /// Where the filter fade takes the outgoing record's corner to: above the
    /// body of a voice and the chords under it, below the hats and the snare's
    /// crack. What is left is rhythm and air.
    public static let filterFadeHz = 1_500.0

    /// The bottom of the sweep — below anything a speaker reproduces, so a
    /// filter set here is in the chain but not in the sound.
    public static let openHz = 20.0

    /// Where the bass swap's corner sits when a record's low end is out.
    public static let bassCutHz = 220.0

    /// The outgoing record's high-pass corner, in hertz, across the mix.
    ///
    /// A blend leaves it open until the swap and takes the bass afterwards. A
    /// filter fade sweeps it up to ``filterFadeHz`` across the first half, so
    /// the melody has gone before the incoming record's bass arrives, and holds
    /// it there while the record fades.
    public static func outgoingHighPassHz(progress: Double, style: DJTransition.Style) -> Double {
        switch style {
        case .blend:
            return sweep(from: openHz, to: bassCutHz, fraction: ramp(progress))
        case .filterFade:
            let progress = clamp(progress)
            let fraction = min(1, progress / swapPoint)
            return sweep(from: openHz, to: filterFadeHz, fraction: fraction)
        case .cut, .echoOut:
            // Nothing overlaps, so nothing is filtered.
            return openHz
        }
    }

    /// The incoming record's, the same either way: its bass is out until the
    /// swap and in after it.
    public static func incomingHighPassHz(progress: Double) -> Double {
        sweep(from: openHz, to: bassCutHz, fraction: 1 - ramp(progress))
    }

    /// Between two corners on a log scale, because that is how frequency is
    /// heard: halfway from 20 Hz to 220 is 66, not 120.
    public static func sweep(from: Double, to: Double, fraction: Double) -> Double {
        from * pow(to / from, clamp(fraction))
    }

    /// How far out the outgoing record's low end is, 0…1: in until the swap,
    /// out after it. The blend's answer; the filter fade's is in
    /// ``outgoingHighPassHz(progress:style:)``.
    public static func outgoingBassCut(progress: Double) -> Double {
        ramp(progress)
    }

    /// And the incoming record's, the other way round.
    public static func incomingBassCut(progress: Double) -> Double {
        1 - ramp(progress)
    }

    /// The outgoing record keeps its bass until the swap, then loses it.
    ///
    /// The same swap in the decibels of the shelf it used to be, kept for the
    /// arithmetic that describes it: the two are complementary in power across
    /// the crossing, which is why the level holds.
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
