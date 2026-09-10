import Foundation
import Testing
@testable import PlaybackKit

/// A four-minute record at `bpm`, gridded from `anchor`, mixable from its first
/// downbeat to sixteen bars before the end.
private func record(
    bpm: Double,
    anchorMs: Double = 0,
    lengthMs: Double = 240_000,
    residualMs: Double = 5,
    key: String? = nil,
    mixInMs: Double? = nil,
    mixOutMs: Double? = nil,
    beatsPerBar: Int? = 4
) -> BeatGrid {
    let barMs = 60_000 / bpm * 4
    return BeatGrid(
        segments: [
            BeatGrid.Segment(
                startMs: 0, endMs: lengthMs, anchorMs: anchorMs, bpm: bpm,
                residualMs: residualMs, beats: Int(lengthMs / (60_000 / bpm))
            )
        ],
        beatsPerBar: beatsPerBar,
        downbeatIndex: beatsPerBar == nil ? nil : 0,
        mixInMs: beatsPerBar == nil ? nil : (mixInMs ?? anchorMs),
        mixOutMs: beatsPerBar == nil ? nil : (mixOutMs ?? (anchorMs + (lengthMs - anchorMs - barMs * 2))),
        key: key,
        keyConfidence: key == nil ? nil : 0.8
    )
}

@Suite("Planning a mix")
struct DJTransitionTests {
    @Test("Two records at one tempo get sixteen bars")
    func straightforward() throws {
        let plan = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 128)))
        #expect(plan.bars == 16)
        // Sixteen bars at 128 is thirty seconds.
        #expect(abs(plan.seconds - 30) < 0.01)
        #expect(plan.outgoingRate == 1)
        #expect(plan.incomingRate == 1)
        #expect(plan.targetBpm == 128)
    }

    @Test("The mix ends where the outgoing record stops being mixable")
    func endsAtMixOut() throws {
        let outgoing = record(bpm: 128, mixOutMs: 180_000)
        let plan = try #require(DJPlanner.plan(outgoing: outgoing, incoming: record(bpm: 128)))
        #expect(abs(plan.outgoingStartMs + plan.seconds * 1000 - 180_000) < 0.01)
    }

    @Test("It starts on a downbeat, a whole number of bars from the anchor")
    func startsOnADownbeat() throws {
        let outgoing = record(bpm: 128, anchorMs: 431.2, mixOutMs: 431.2 + 1875 * 64)
        let plan = try #require(DJPlanner.plan(outgoing: outgoing, incoming: record(bpm: 128)))
        let bars = (plan.outgoingStartMs - 431.2) / 1875
        #expect(abs(bars - bars.rounded()) < 1e-6)
    }

    @Test("The incoming record is the one that bends, and only so far")
    func bending() throws {
        // 126 into 128 is a sixteenth of a semitone; well inside the fader.
        let plan = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 126)))
        #expect(plan.outgoingRate == 1)
        #expect(abs(plan.incomingRate - 128.0 / 126.0) < 1e-9)

        // 100 into 128 is not a bend, it is a different record.
        #expect(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 100)) == nil)
    }

    @Test("Double time counts, and is not slowed down to prove it")
    func doubleTime() throws {
        let plan = try #require(DJPlanner.plan(outgoing: record(bpm: 85), incoming: record(bpm: 170)))
        // Played at its own speed: at 170 over 85, every other beat already
        // lands on the other record's, which is the whole reason the octave is
        // folded rather than the record slowed.
        #expect(abs(plan.incomingRate - 1) < 1e-9)

        // And the same in reverse — the slow record over the fast one.
        let reversed = try #require(DJPlanner.plan(outgoing: record(bpm: 170), incoming: record(bpm: 85)))
        #expect(abs(reversed.incomingRate - 1) < 1e-9)
    }

    @Test("Six per cent is the limit either way")
    func stretchLimit() {
        #expect(DJPlanner.bendableRate(from: 128, to: 128 * 1.06) != nil)
        #expect(DJPlanner.bendableRate(from: 128, to: 128 * 1.07) == nil)
        #expect(DJPlanner.bendableRate(from: 128, to: 128 / 1.06) != nil)
        #expect(DJPlanner.bendableRate(from: 128, to: 128 / 1.07) == nil)
        #expect(DJPlanner.bendableRate(from: 0, to: 128) == nil)
        #expect(DJPlanner.bendableRate(from: .infinity, to: 128) == nil)
    }

    @Test("Eight bars when sixteen will not fit, and nothing when eight will not")
    func fallsBackToEight() throws {
        // Only twenty seconds of mixable record left: sixteen bars is thirty.
        let cramped = record(bpm: 128, mixOutMs: 20_000)
        let plan = try #require(DJPlanner.plan(outgoing: cramped, incoming: record(bpm: 128)))
        #expect(plan.bars == 8)

        let tooCramped = record(bpm: 128, mixOutMs: 10_000)
        #expect(DJPlanner.plan(outgoing: tooCramped, incoming: record(bpm: 128)) == nil)
    }

    @Test("A mix cannot start before the engine could have got ready")
    func notBefore() {
        let outgoing = record(bpm: 128, mixOutMs: 180_000)
        // The mix would start at 150s; being told nothing may start before 160s
        // rules out sixteen bars, and eight bars starts at 165s.
        let plan = DJPlanner.plan(outgoing: outgoing, incoming: record(bpm: 128), notBeforeMs: 160_000)
        #expect(plan?.bars == 8)
        #expect(DJPlanner.plan(outgoing: outgoing, incoming: record(bpm: 128), notBeforeMs: 179_000) == nil)
    }

    @Test("No meter, no mix")
    func noMeter() {
        #expect(DJPlanner.plan(outgoing: record(bpm: 128, beatsPerBar: nil), incoming: record(bpm: 128)) == nil)
        #expect(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 128, beatsPerBar: nil)) == nil)
    }

    @Test("A grid its own record does not sit on is not one to mix to")
    func looseGrid() {
        let sloppy = record(bpm: 128, residualMs: 60)
        #expect(DJPlanner.plan(outgoing: sloppy, incoming: record(bpm: 128)) == nil)
        #expect(DJPlanner.plan(outgoing: record(bpm: 128), incoming: sloppy) == nil)
    }

    @Test("The incoming record must have the bars to give")
    func incomingTooShort() {
        // Mixable from 100s, but the record stops at 110s: ten seconds is not
        // sixteen bars, and not eight either.
        let stub = record(bpm: 128, lengthMs: 110_000, mixInMs: 100_000, mixOutMs: 105_000)
        #expect(DJPlanner.plan(outgoing: record(bpm: 128), incoming: stub) == nil)
    }

    @Test("A bent record is consumed faster than the clock, and must have that much")
    func bendEatsMoreRecord() throws {
        // 121.9 into 128 is a bend of 1.05: thirty seconds of mix eats thirty-one
        // and a half seconds of the incoming record. This one has thirty-one from
        // its mix-in — enough by the clock, not enough by the record, which is a
        // distinction only the rate makes.
        let short = record(bpm: 121.9, lengthMs: 131_000, mixInMs: 100_000, mixOutMs: 120_000)
        let cramped = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: short))
        #expect(cramped.bars == 8)

        // Two more seconds of record and the same pair gets the full sixteen.
        let longer = record(bpm: 121.9, lengthMs: 133_000, mixInMs: 100_000, mixOutMs: 120_000)
        let full = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: longer))
        #expect(full.bars == 16)
    }

    @Test("Records that clash get the short mix, not the long one")
    func clashingKeysShortenTheMix() throws {
        // 3B against 10B: seven steps apart on the wheel, which is two keys with
        // little in common held against each other for however long the mix runs.
        let clashing = try #require(DJPlanner.plan(
            outgoing: record(bpm: 128, key: "3B"),
            incoming: record(bpm: 128, key: "10B")
        ))
        #expect(clashing.bars == DJPlanner.minimumBars)
        #expect(!clashing.isKeyCompatible)

        // Neighbours keep the full sixteen.
        let related = try #require(DJPlanner.plan(
            outgoing: record(bpm: 128, key: "8A"),
            incoming: record(bpm: 128, key: "9A")
        ))
        #expect(related.bars == DJPlanner.preferredBars)

        // And an unmeasured key is not a clash — most of a library has no key at
        // all, and shortening every mix on that basis would be shortening every
        // mix.
        let unmeasured = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 128)))
        #expect(unmeasured.bars == DJPlanner.preferredBars)
    }

    @Test("Both ends are put on the grid, whatever the mix points say")
    func snapsToDownbeats() throws {
        // A mix-out point half a beat off its own grid — which the server does
        // not do, and which would otherwise make every mix on this record half a
        // beat out.
        let bar = 1_875.0
        let crooked = record(bpm: 128, anchorMs: 0, mixOutMs: 200_000 + 234)
        let incoming = record(bpm: 128, anchorMs: 100, mixInMs: 40_000 + 51)
        let plan = try #require(DJPlanner.plan(outgoing: crooked, incoming: incoming))

        let outBars = plan.outgoingStartMs / bar
        #expect(abs(outBars - outBars.rounded()) < 1e-6, "start at \(plan.outgoingStartMs)ms")
        let inBars = (plan.incomingStartMs - 100) / bar
        #expect(abs(inBars - inBars.rounded()) < 1e-6, "entry at \(plan.incomingStartMs)ms")
    }

    @Test("Keys are noted, never enforced")
    func keys() throws {
        let related = try #require(DJPlanner.plan(
            outgoing: record(bpm: 128, key: "8A"),
            incoming: record(bpm: 128, key: "9A")
        ))
        #expect(related.isKeyCompatible)

        // A clash still mixes. The estimator has never seen real music, and a
        // refusal on it would be a refusal on a guess.
        let clashing = try #require(DJPlanner.plan(
            outgoing: record(bpm: 128, key: "8A"),
            incoming: record(bpm: 128, key: "2B")
        ))
        #expect(!clashing.isKeyCompatible)

        let unmeasured = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 128)))
        #expect(!unmeasured.isKeyCompatible)
    }

    @Test("The bend does not outlive the mix")
    func restores() throws {
        let plan = try #require(DJPlanner.plan(outgoing: record(bpm: 128), incoming: record(bpm: 126)))
        #expect(plan.restoreSeconds == DJPlanner.restoreSeconds)
        #expect(plan.restoreSeconds > 0)
    }
}

@Suite("What each deck does across a mix")
struct DJAutomationTests {
    private func linear(_ db: Double) -> Double { pow(10, db / 20) }

    @Test("Neither fader moves while the low end is still deciding")
    func fadersHoldUntilTheSwap() {
        // The record carrying the bass is the record in front; turning it down
        // before it hands the bass over is turning the mix down, which is the
        // defect this replaced.
        for step in 0...5 {
            let progress = Double(step) / 5 * DJAutomation.swapPoint
            #expect(DJAutomation.outgoingGain(progress: progress) == 1)
        }
        // And the incoming record is at full within about a bar of arriving.
        #expect(DJAutomation.incomingGain(progress: 0) == 0)
        #expect(DJAutomation.incomingGain(progress: DJAutomation.entryWidth) == 1)
        #expect(DJAutomation.incomingGain(progress: 0.5) == 1)
    }

    @Test("The outgoing record leaves after the bass does, not before")
    func outgoingLeavesLast() {
        #expect(DJAutomation.outgoingGain(progress: 0.5) == 1)
        #expect(DJAutomation.outgoingGain(progress: 0.75) < 1)
        #expect(DJAutomation.outgoingGain(progress: 0.75) > 0)
        #expect(abs(DJAutomation.outgoingGain(progress: 1)) < 1e-9)
        // Monotonic: a fade that goes back up is a fade somebody hears.
        var previous = 1.0
        for step in 0...20 {
            let gain = DJAutomation.outgoingGain(progress: Double(step) / 20)
            #expect(gain <= previous + 1e-12)
            previous = gain
        }
    }

    @Test("The bass swaps at constant power, not at constant decibels")
    func bassSwapsWithoutAHole() {
        // Two shelves meeting halfway down their travel are twelve decibels down
        // each, and twelve down on both records at once is the hole that measured
        // four and a half decibels in a rendered mix. Meeting at −3 keeps the low
        // end's power flat across the crossing.
        let middle = DJAutomation.swapPoint
        #expect(abs(DJAutomation.outgoingBassDb(progress: middle) - -3.0103) < 0.01)
        #expect(abs(DJAutomation.incomingBassDb(progress: middle) - -3.0103) < 0.01)

        for step in 0...40 {
            let progress = Double(step) / 40
            let out = linear(DJAutomation.outgoingBassDb(progress: progress))
            let into = linear(DJAutomation.incomingBassDb(progress: progress))
            let power = out * out + into * into
            // Away from the swap one record is at full and the other is at the
            // floor, which is a hair over one; through it the two sum to one.
            #expect(power > 0.99 && power < 1.02, "low-end power \(power) at \(progress)")
        }
    }

    @Test("Either side of the swap, one record has the low end and one does not")
    func bassBelongsToOne() {
        #expect(DJAutomation.outgoingBassDb(progress: 0.1) == 0)
        #expect(DJAutomation.incomingBassDb(progress: 0.1) == DJAutomation.bassCutDb)
        #expect(DJAutomation.outgoingBassDb(progress: 0.9) == DJAutomation.bassCutDb)
        #expect(DJAutomation.incomingBassDb(progress: 0.9) == 0)
    }

    @Test("The swap happens in the middle, where the downbeat is")
    func swapPoint() {
        #expect(abs(DJAutomation.ramp(DJAutomation.swapPoint) - 0.5) < 1e-9)
        #expect(DJAutomation.ramp(DJAutomation.swapPoint - DJAutomation.swapWidth) == 0)
        #expect(DJAutomation.ramp(DJAutomation.swapPoint + DJAutomation.swapWidth) == 1)
    }

    @Test("A progress outside the mix stays inside it")
    func clamped() {
        #expect(DJAutomation.ramp(-1) == 0)
        #expect(DJAutomation.ramp(2) == 1)
        #expect(DJAutomation.ramp(.nan) == 0)
        #expect(DJAutomation.outgoingGain(progress: .nan) == 1)
        #expect(DJAutomation.incomingGain(progress: .nan) == 0)
    }
}
