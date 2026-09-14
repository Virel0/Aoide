import Foundation
import Testing
@testable import PlaybackKit

private let bar = 60_000.0 / 128 * 4

private func grid(mixOutMs: Double) -> BeatGrid {
    BeatGrid(
        segments: [BeatGrid.Segment(startMs: 0, endMs: 240_000, anchorMs: 0, bpm: 128, residualMs: 4, beats: 512)],
        beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: mixOutMs
    )
}

private func arrangement(_ parts: [(Arrangement.Kind, Int, Double)], phraseBars: Int? = 16, vocals: [Arrangement.Span]? = []) -> Arrangement {
    var sections: [Arrangement.Section] = []
    var at = 0.0
    for (kind, bars, energy) in parts {
        sections.append(.init(startMs: at, endMs: at + bar * Double(bars), kind: kind, energy: energy))
        at += bar * Double(bars)
    }
    return Arrangement(sections: sections, phraseBars: phraseBars, phraseAnchorMs: phraseBars == nil ? nil : 0, vocals: vocals)
}

@Suite("Programming the set")
struct SetProgrammerTests {
    @Test("A radio edit plays for about sixty per cent of itself")
    func popTarget() {
        // Three and a half minutes: two minutes six.
        #expect(SetProgrammer.targetMs(durationMs: 210_000) == 126_000)
        // Never less than a minute and a half, however short the record.
        #expect(SetProgrammer.targetMs(durationMs: 100_000) == 90_000)
        // A record shorter than that plays out.
        #expect(SetProgrammer.targetMs(durationMs: 80_000) == 80_000)
        // A seven-minute club record is ridden for its groove, not all of it.
        #expect(SetProgrammer.targetMs(durationMs: 420_000) == 252_000)
        #expect(SetProgrammer.targetMs(durationMs: 600_000) == 300_000)
    }

    @Test("Leaves out of a drop, near the target, on a phrase line")
    func leavesOutOfADrop() throws {
        // 128 bars at 128 BPM is four minutes. Intro 16, drop 32, breakdown 16,
        // drop 32, outro 32. Target is 60% ≈ bar 77; the drops end at bars 48
        // and 96. Bar 96 is closer to 77 than 48 is, and it is a phrase line.
        let a = arrangement([(.intro, 16, 0.2), (.drop, 32, 0.9), (.breakdown, 16, 0.4), (.drop, 32, 1.0), (.outro, 32, 0.2)])
        let exit = try #require(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: a, durationMs: bar * 128))
        #expect(abs(exit - bar * 96) < 0.01)
    }

    @Test("An exit on a bar line stays on it: the hook ends where it ends")
    func exitStaysOnItsBar() throws {
        // The second drop ends at bar 101 — five bars past the phrase line at
        // 96. The server put that boundary on a bar because the music changed
        // there, not on the phrase line; pulling it back to 96 would leave in
        // the last five bars of the hook, which is leaving early. Within two
        // bars of a phrase line, though, the line is taken.
        let late = arrangement([(.intro, 16, 0.2), (.drop, 32, 0.9), (.breakdown, 21, 0.4), (.drop, 32, 1.0), (.outro, 27, 0.2)])
        let exit = try #require(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: late, durationMs: bar * 128))
        #expect(abs(exit - bar * 101) < 0.01, "exit at bar \(exit / bar)")

        let near = arrangement([(.intro, 16, 0.2), (.drop, 32, 0.9), (.breakdown, 18, 0.4), (.drop, 32, 1.0), (.outro, 30, 0.2)])
        let snapped = try #require(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: near, durationMs: bar * 128))
        #expect(abs(snapped - bar * 96) < 0.01, "exit at bar \(snapped / bar)")
    }

    @Test("An escape leaves at the end of the last hook, not the nearest to the target")
    func lateExit() throws {
        // Two drops end at bars 48 and 96; the target is bar 77. The mix
        // leaves at 96, the closer; the escape leaves at 96 too here — the
        // last. Add a third drop ending at bar 120, past the mix-out at 116,
        // and the escape is still 96: never past the record's own mix-out.
        let a = arrangement([(.intro, 16, 0.2), (.drop, 32, 0.9), (.breakdown, 16, 0.4), (.drop, 32, 1.0), (.outro, 32, 0.2)])
        let late = try #require(SetProgrammer.lateExitMs(grid: grid(mixOutMs: bar * 116), arrangement: a, durationMs: bar * 128))
        #expect(abs(late - bar * 96) < 0.01)

        // Three drops ending at 48, 80 and 112; target bar 77. The mix leaves
        // at 80; the escape at 112.
        let three = arrangement([(.intro, 16, 0.2), (.drop, 32, 0.9), (.breakdown, 8, 0.4), (.drop, 24, 1.0), (.breakdown, 8, 0.4), (.drop, 24, 1.0), (.outro, 16, 0.2)])
        let early = try #require(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128))
        #expect(abs(early - bar * 80) < 0.01, "mix exit at bar \(early / bar)")
        let escape = try #require(SetProgrammer.lateExitMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128))
        #expect(abs(escape - bar * 112) < 0.01, "escape at bar \(escape / bar)")
    }

    @Test("Never before forty per cent, never after the record's own mix-out")
    func bounds() throws {
        // A drop that ends at bar 24 (19%) is too early to leave on; the next
        // ends at bar 96.
        let early = arrangement([(.intro, 8, 0.2), (.drop, 16, 0.9), (.breakdown, 40, 0.4), (.drop, 32, 1.0), (.outro, 32, 0.2)])
        let exit = try #require(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: early, durationMs: bar * 128))
        #expect(abs(exit - bar * 96) < 0.01)

        // A drop ending past the mix-out point is past where the record can be
        // left at all.
        let late = arrangement([(.intro, 16, 0.2), (.drop, 100, 0.9), (.outro, 12, 0.2)])
        #expect(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 110), arrangement: late, durationMs: bar * 128) == nil)
    }

    @Test("A record with no drop plays out")
    func noDrop() {
        let flat = arrangement([(.unknown, 128, 0.5)])
        #expect(SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: flat, durationMs: bar * 128) == nil)
    }

    @Test("Into a louder section is not a way out")
    func notIntoLouder() {
        // A drop followed by something louder still is not the end of the hook.
        let rising = arrangement([(.intro, 16, 0.2), (.drop, 48, 0.7), (.drop, 48, 1.0), (.outro, 16, 0.2)])
        let exit = SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 120), arrangement: rising, durationMs: bar * 128)
        // Only the second drop's end qualifies: bar 112, which is the outro's start.
        #expect(exit.map { abs($0 - bar * 112) < 0.01 } == true)
    }
}

@Suite("The exit chosen for the pair")
struct PairedExitTests {
    // 128 bars at 128. Three hooks end at bars 56, 84 and 112 — all past the
    // forty per cent floor at bar 51; the target is bar 77, so the set's own
    // choice is 84, then 56, then 112.
    private let three = arrangement([(.intro, 16, 0.2), (.drop, 40, 0.9), (.breakdown, 8, 0.4), (.drop, 20, 1.0), (.breakdown, 8, 0.4), (.drop, 20, 1.0), (.outro, 16, 0.2)])
    private let plain = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)])

    @Test("The candidates are every hook's end, best first")
    func candidates() {
        let exits = SetProgrammer.exitCandidatesMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128)
        #expect(exits.map { Int(($0 / bar).rounded()) } == [84, 56, 112])
        // The first is the set's own single choice; the last the escape's.
        #expect(exits.first == SetProgrammer.exitMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128))
        #expect(exits.max() == SetProgrammer.lateExitMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128))
    }

    @Test("The set's own exit stands unless another mixes clearly better")
    func preferenceHolds() throws {
        let exits = SetProgrammer.exitCandidatesMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128)
        // Against a plain record, every exit leaves a drop into the same
        // intro: the scores tie, and the set's choice — bar 84 — stands.
        let tied = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: three, incomingArrangement: plain,
            outgoingExitsMs: exits
        ))
        #expect(abs(tied.outgoingStartMs + tied.seconds * 1000 - bar * 84) < 0.01, "left at bar \((tied.outgoingStartMs + tied.seconds * 1000) / bar)")

        // A single exit given is the exit taken: the old call, unchanged.
        let single = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: three, incomingArrangement: plain,
            outgoingExitMs: bar * 112
        ))
        #expect(abs(single.outgoingStartMs + single.seconds * 1000 - bar * 112) < 0.01)

        // And none given is the record's own mix-out.
        let own = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: three, incomingArrangement: plain,
            outgoingExitsMs: []
        ))
        #expect(abs(own.outgoingStartMs + own.seconds * 1000 - bar * 116) < 0.01)
    }

    @Test("A clearly better mix from another exit is taken")
    func betterExitWins() throws {
        // The outgoing record sings across the bars before its second hook's
        // end at bar 84, and that hook is its loudest; the first hook, ending
        // at 56, is quieter and instrumental. The incoming record comes in
        // on a build at half energy, silent. Leaving at 84: one voice under
        // the new record (0.6 on vocals) and a 0.5 energy step. Leaving at
        // 56: nobody singing (1.0) and a 0.1 step. The second scores 0.14
        // more — over the margin — so the set leaves early, at 56, for this
        // pair, though 84 is its own choice.
        let sung = arrangement(
            [(.intro, 16, 0.2), (.drop, 40, 0.6), (.breakdown, 8, 0.4), (.drop, 20, 1.0), (.breakdown, 8, 0.4), (.drop, 20, 1.0), (.outro, 16, 0.2)],
            vocals: [.init(startMs: bar * 60, endMs: bar * 120)]
        )
        let onABuild = arrangement([(.intro, 8, 0.2), (.build, 8, 0.5), (.drop, 96, 0.9), (.outro, 16, 0.2)])
        let exits = SetProgrammer.exitCandidatesMs(grid: grid(mixOutMs: bar * 116), arrangement: sung, durationMs: bar * 128)
        #expect(exits.first.map { Int(($0 / bar).rounded()) } == 84)
        let atOwn = try #require(DJPlanner.plan(outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112), outgoingArrangement: sung, incomingArrangement: onABuild, outgoingExitMs: exits[0]))
        let atEarly = try #require(DJPlanner.plan(outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112), outgoingArrangement: sung, incomingArrangement: onABuild, outgoingExitMs: exits[1]))
        #expect(atEarly.score.total - atOwn.score.total >= DJPlanner.exitPreferenceMargin, "gap \(atEarly.score.total - atOwn.score.total)")
        let moved = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: sung, incomingArrangement: onABuild,
            outgoingExitsMs: exits
        ))
        #expect(abs(moved.outgoingStartMs + moved.seconds * 1000 - bar * 56) < 0.01, "left at bar \((moved.outgoingStartMs + moved.seconds * 1000) / bar)")

        // And when the set's own exit cannot be mixed from at all — two
        // voices — the best of the rest is taken without a margin to clear.
        let singing = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [.init(startMs: 0, endMs: bar * 128)])
        let escapedTo = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: sung, incomingArrangement: singing,
            outgoingExitsMs: exits
        ))
        #expect(abs(escapedTo.outgoingStartMs + escapedTo.seconds * 1000 - bar * 56) < 0.01)
    }

    @Test("A marginally better mix from another exit is not")
    func marginIsReal() throws {
        // Leaving at 84 or at 56 lands the join on the same record; the two
        // scores differ by less than the margin. The set's choice stands.
        let withBuild = arrangement([(.intro, 8, 0.2), (.build, 8, 0.5), (.drop, 96, 0.9), (.outro, 16, 0.2)])
        let exits = SetProgrammer.exitCandidatesMs(grid: grid(mixOutMs: bar * 116), arrangement: three, durationMs: bar * 128)
        let a = try #require(DJPlanner.plan(outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112), outgoingArrangement: three, incomingArrangement: withBuild, outgoingExitMs: exits[0]))
        let b = try #require(DJPlanner.plan(outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112), outgoingArrangement: three, incomingArrangement: withBuild, outgoingExitMs: exits[1]))
        let gap = abs(a.score.total - b.score.total)
        #expect(gap < DJPlanner.exitPreferenceMargin, "gap \(gap)")
        let chosen = try #require(DJPlanner.plan(
            outgoing: grid(mixOutMs: bar * 116), incoming: grid(mixOutMs: bar * 112),
            outgoingArrangement: three, incomingArrangement: withBuild,
            outgoingExitsMs: exits
        ))
        #expect(abs(chosen.outgoingStartMs + chosen.seconds * 1000 - bar * 84) < 0.01)
    }
}
