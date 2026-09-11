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

private func arrangement(_ parts: [(Arrangement.Kind, Int, Double)], phraseBars: Int? = 16) -> Arrangement {
    var sections: [Arrangement.Section] = []
    var at = 0.0
    for (kind, bars, energy) in parts {
        sections.append(.init(startMs: at, endMs: at + bar * Double(bars), kind: kind, energy: energy))
        at += bar * Double(bars)
    }
    return Arrangement(sections: sections, phraseBars: phraseBars, phraseAnchorMs: phraseBars == nil ? nil : 0, vocals: [])
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
