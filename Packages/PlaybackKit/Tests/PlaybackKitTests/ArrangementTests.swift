import Foundation
import Testing
@testable import PlaybackKit

/// A four-minute record at 128, mixable from bar 8 to sixteen bars before the end.
private let bar = 60_000.0 / 128 * 4
private func grid(anchorMs: Double = 0, mixInMs: Double? = nil) -> BeatGrid {
    BeatGrid(
        segments: [BeatGrid.Segment(startMs: 0, endMs: 240_000, anchorMs: anchorMs, bpm: 128, residualMs: 4, beats: 512)],
        beatsPerBar: 4,
        downbeatIndex: 0,
        mixInMs: mixInMs ?? anchorMs + bar * 8,
        mixOutMs: anchorMs + bar * 112
    )
}

/// Sections in bars, laid end to end.
private func arrangement(
    _ parts: [(Arrangement.Kind, Int, Double)],
    phraseBars: Int? = 16,
    anchorMs: Double = 0,
    vocals: [Arrangement.Span]? = []
) -> Arrangement {
    var sections: [Arrangement.Section] = []
    var at = 0.0
    for (kind, bars, energy) in parts {
        sections.append(Arrangement.Section(startMs: at, endMs: at + bar * Double(bars), kind: kind, energy: energy))
        at += bar * Double(bars)
    }
    return Arrangement(sections: sections, phraseBars: phraseBars, phraseAnchorMs: phraseBars == nil ? nil : anchorMs, vocals: vocals)
}

private let plain = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)])

@Suite("What a mix can see, now that it can see the music")
struct ArrangementTests {
    @Test("A mix starts on a phrase, not merely on a bar")
    func phraseAligned() throws {
        // Mix-out at bar 112; sixteen bars back is bar 96, which is a phrase
        // line. Move the mix-out to bar 115 and sixteen back is bar 99 — a bar
        // line and not a phrase line — so the start goes back to 96.
        let crooked = BeatGrid(
            segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0,
            mixInMs: bar * 8, mixOutMs: bar * 115
        )
        let plan = try #require(DJPlanner.plan(
            outgoing: crooked, incoming: grid(),
            outgoingArrangement: plain, incomingArrangement: plain
        ))
        #expect(abs(plan.outgoingStartMs - bar * 96) < 0.01)

        // And the entry: mix-in at bar 8 sits on the phrase line already. At bar
        // 11 it would come in three bars into a phrase, so it comes in at 0.
        let lateEntry = grid(mixInMs: bar * 11)
        let entered = try #require(DJPlanner.plan(
            outgoing: grid(), incoming: lateEntry,
            outgoingArrangement: plain, incomingArrangement: plain
        ))
        #expect(abs(entered.incomingStartMs - 0) < 0.01)

        // Without a phrase grid, a bar line is the best there is.
        let noPhrases = arrangement([(.unknown, 128, 0.5)], phraseBars: nil)
        let barred = try #require(DJPlanner.plan(
            outgoing: crooked, incoming: lateEntry,
            outgoingArrangement: noPhrases, incomingArrangement: noPhrases
        ))
        #expect(abs(barred.outgoingStartMs - bar * 99) < 0.01)
        #expect(abs(barred.incomingStartMs - bar * 11) < 0.01)
    }

    @Test("Two records singing at once is not a mix")
    func noTwoVoices() {
        // The outgoing record sings through its last minute; the incoming one
        // sings from its first bar.
        let singingOut = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: bar * 90, endMs: bar * 128)])
        let singingIn = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: 0, endMs: bar * 40)])
        #expect(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: singingOut, incomingArrangement: singingIn
        ) == nil)

        // One voice is fine. The incoming record's singing starts after the mix
        // would be over.
        let singsLater = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: bar * 40, endMs: bar * 80)])
        #expect(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: singingOut, incomingArrangement: singsLater
        ) != nil)
    }

    @Test("Not being able to tell counts as singing")
    func unknownVocalsCount() {
        let cannotTell = arrangement([(.drop, 128, 0.9)], vocals: nil)
        let sings = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: 0, endMs: bar * 128)])
        #expect(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: cannotTell, incomingArrangement: sings
        ) == nil)
        // Looked and found none is not the same as could not tell.
        let instrumental = arrangement([(.drop, 128, 0.9)], vocals: [])
        #expect(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: cannotTell, incomingArrangement: instrumental
        ) != nil)
    }

    @Test("A drop onto a drop gets eight bars, not sixteen")
    func dropOnDrop() throws {
        // The outgoing record's mix-out is inside its drop and the incoming
        // record comes in on its own drop.
        let dropOut = arrangement([(.intro, 16, 0.2), (.drop, 112, 0.9)])
        let dropIn = arrangement([(.drop, 128, 0.9)])
        let plan = try #require(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: dropOut, incomingArrangement: dropIn
        ))
        #expect(plan.bars == 8)

        // Coming in on a build is what a DJ does, and keeps the sixteen.
        let buildIn = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)])
        let long = try #require(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: dropOut, incomingArrangement: buildIn
        ))
        #expect(long.bars == 16)
    }

    @Test("Without an arrangement, nothing here applies")
    func absentIsAbsent() throws {
        let plan = try #require(DJPlanner.plan(outgoing: grid(), incoming: grid()))
        #expect(plan.bars == 16)
    }

    @Test("Reading the arrangement")
    func lookups() {
        let a = arrangement([(.intro, 16, 0.1), (.drop, 96, 1.0), (.outro, 16, 0.2)], vocals: [.init(startMs: 1_000, endMs: 2_000)])
        #expect(a.section(at: 0)?.kind == .intro)
        #expect(a.section(at: bar * 16)?.kind == .drop)
        #expect(a.section(at: bar * 200)?.kind == .outro)
        #expect(a.maySing(from: 500, to: 1_500))
        #expect(!a.maySing(from: 2_000, to: 3_000))
        #expect(a.phraseStart(atOrBefore: bar * 21, barMs: bar).map { abs($0 - bar * 16) < 0.01 } == true)
        #expect(Arrangement(sections: []).phraseStart(atOrBefore: 10, barMs: bar) == nil)
    }
}
