import Foundation
import Testing
@testable import PlaybackKit

/// The same forty pairs the desktop plans, with the same forty plans.
///
/// "Both apps mix the same way" is a claim, and this table is the only thing
/// that makes it one: it is duplicated verbatim in the desktop's
/// `dj-planner-parity.test.ts`, so either side changing a constant, a
/// threshold, a snapping rule or an ordering breaks its own copy. Starts and
/// entries are exact milliseconds and the score is the exact double, because
/// two planners a bar apart are still two planners.

private let bar = 60_000.0 / 128 * 4

/// A four-minute record at `bpm`, gridded from `anchor`, mixable from its first
/// downbeat to two bars before the end.
private func record(
    _ bpm: Double,
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

/// A four-minute record at 128, mixable from bar 8 to sixteen bars before the end.
private func grid(mixInMs: Double? = nil, mixOutMs: Double? = nil, key: String? = nil) -> BeatGrid {
    record(128, key: key, mixInMs: mixInMs ?? bar * 8, mixOutMs: mixOutMs ?? bar * 112)
}

/// Sections in bars, laid end to end.
private func arrangement(
    _ parts: [(Arrangement.Kind, Int, Double)],
    phraseBars: Int? = 16,
    vocals: [Arrangement.Span]? = []
) -> Arrangement {
    var sections: [Arrangement.Section] = []
    var at = 0.0
    for (kind, bars, energy) in parts {
        sections.append(Arrangement.Section(startMs: at, endMs: at + bar * Double(bars), kind: kind, energy: energy))
        at += bar * Double(bars)
    }
    return Arrangement(sections: sections, phraseBars: phraseBars, phraseAnchorMs: phraseBars == nil ? nil : 0, vocals: vocals)
}

private let plain = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)])
private let dropOut = arrangement([(.intro, 16, 0.2), (.drop, 112, 0.9)])
private let dropIn = arrangement([(.drop, 128, 0.9)])
private let buildIn = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)])
private let withBuild = arrangement([(.intro, 16, 0.2), (.build, 16, 0.5), (.drop, 80, 0.95), (.outro, 16, 0.2)])
private let midEnergy = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.55), (.outro, 16, 0.2)])
private let breakdownOut = arrangement([(.intro, 16, 0.2), (.drop, 80, 0.9), (.breakdown, 16, 0.5), (.outro, 16, 0.2)])
private let singingOut = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: bar * 90, endMs: bar * 128)])
private let singingIn = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: 0, endMs: bar * 40)])
private let singsLater = arrangement([(.drop, 128, 0.9)], vocals: [.init(startMs: bar * 40, endMs: bar * 80)])
private let cannotTell = arrangement([(.drop, 128, 0.9)], vocals: nil)
private let instrumental = arrangement([(.drop, 128, 0.9)])
private let noPhrases = arrangement([(.unknown, 128, 0.5)], phraseBars: nil)
private let buildThenDrop = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)])
private let singingThroughout = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)], vocals: [.init(startMs: 0, endMs: bar * 128)])
/// A loud drop throughout, sung from bar 80 to bar 90 and nowhere else.
private let singsAtEighty = arrangement([(.drop, 128, 1)], vocals: [.init(startMs: bar * 80, endMs: bar * 90)])
/// A silent drop throughout: the worst energy match for the one above.
private let quietDrop = arrangement([(.drop, 128, 0)])

/// A record that has been read and found unremarkable: one section nobody
/// could name, instrumental, no phrase grid. The planner refuses a record that
/// has not been read at all, so the grid-only rows are handed one of these.
/// The two energies differ so that a pair with nothing else going for it lands
/// on sixteen bars rather than being flattered into thirty-two.
private func read(energy: Double) -> Arrangement {
    Arrangement(
        sections: [Arrangement.Section(startMs: 0, endMs: 600_000, kind: .unknown, energy: energy)],
        vocals: []
    )
}

/// The slower record in "bend eats record": 128 over 1.01, mixable from bar 50.
private let slowBpm = 128 / 1.01
private let slowMixIn = 60_000 / slowBpm * 4 * 50

private struct ParityCase: Sendable, CustomTestStringConvertible {
    let why: String
    let outgoing: BeatGrid
    let incoming: BeatGrid
    var notBeforeMs: Double = 0
    var outgoingArrangement: Arrangement? = nil
    var incomingArrangement: Arrangement? = nil
    let bars: Int?
    var outgoingStartMs: Double = 0
    var incomingStartMs: Double = 0
    var incomingRate: Double = 1
    var total: Double = 0
    var style: DJTransition.Style = .blend

    /// Both records read and unremarkable.
    static func unremarkable(
        why: String, outgoing: BeatGrid, incoming: BeatGrid, notBeforeMs: Double = 0,
        bars: Int?, outgoingStartMs: Double = 0, incomingStartMs: Double = 0, incomingRate: Double = 1,
        total: Double = 0, style: DJTransition.Style = .blend
    ) -> ParityCase {
        ParityCase(
            why: why, outgoing: outgoing, incoming: incoming, notBeforeMs: notBeforeMs,
            outgoingArrangement: read(energy: 0.8), incomingArrangement: read(energy: 0.2),
            bars: bars, outgoingStartMs: outgoingStartMs, incomingStartMs: incomingStartMs,
            incomingRate: incomingRate, total: total, style: style
        )
    }

    var testDescription: String { why }
}

private let parityTable: [ParityCase] = [
    .unremarkable(
        why: "two records at one tempo get sixteen bars",
        outgoing: record(128), incoming: record(128),
        bars: 16, outgoingStartMs: 206_250, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "the mix ends where the outgoing record stops being mixable",
        outgoing: record(128, mixOutMs: 180_000), incoming: record(128),
        bars: 16, outgoingStartMs: 150_000, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "an anchor off zero keeps the start on its own downbeats",
        outgoing: record(128, anchorMs: 431.2, mixOutMs: 431.2 + 1875 * 64), incoming: record(128),
        bars: 16, outgoingStartMs: 90_431.2, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "126 into 128 bends the incoming record up",
        outgoing: record(128), incoming: record(126),
        bars: 16, outgoingStartMs: 206_250, incomingStartMs: 0, incomingRate: 1.0158730158730158, total: 0.68
    ),
    .unremarkable(
        why: "130 into 128 bends it down",
        outgoing: record(128), incoming: record(130),
        bars: 16, outgoingStartMs: 206_250, incomingStartMs: 0, incomingRate: 0.9846153846153847, total: 0.68
    ),
    .unremarkable(
        why: "100 into 128 is not a bend, it is a different record",
        outgoing: record(128), incoming: record(100),
        bars: nil
    ),
    .unremarkable(
        why: "double time is played at its own speed",
        outgoing: record(85), incoming: record(170),
        bars: 16, outgoingStartMs: 189_176.4705882353, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "and so is half time",
        outgoing: record(170), incoming: record(85),
        bars: 16, outgoingStartMs: 214_588.23529411765, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "eight bars when sixteen will not fit",
        outgoing: record(128, mixOutMs: 20_000), incoming: record(128),
        bars: 8, outgoingStartMs: 3_750, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "and nothing when eight will not",
        outgoing: record(128, mixOutMs: 10_000), incoming: record(128),
        bars: nil
    ),
    .unremarkable(
        why: "a mix cannot start before the engine could have got ready",
        outgoing: record(128, mixOutMs: 180_000), incoming: record(128), notBeforeMs: 160_000,
        bars: 8, outgoingStartMs: 165_000, incomingStartMs: 0, incomingRate: 1, total: 0.68
    ),
    .unremarkable(
        why: "and too late is a crossfade",
        outgoing: record(128, mixOutMs: 180_000), incoming: record(128), notBeforeMs: 179_000,
        bars: nil
    ),
    .unremarkable(
        why: "no meter behind, no mix",
        outgoing: record(128, beatsPerBar: nil), incoming: record(128),
        bars: nil
    ),
    .unremarkable(
        why: "no meter ahead, no mix",
        outgoing: record(128), incoming: record(128, beatsPerBar: nil),
        bars: nil
    ),
    .unremarkable(
        why: "a grid its own record does not sit on is not one to mix to",
        outgoing: record(128), incoming: record(128, residualMs: 60),
        bars: nil
    ),
    .unremarkable(
        why: "the incoming record must have the bars to give",
        outgoing: record(128), incoming: record(128, lengthMs: 110_000, mixInMs: 100_000, mixOutMs: 105_000),
        bars: nil
    ),
    .unremarkable(
        why: "a bent record is consumed faster than the clock: thirty seconds is not enough",
        outgoing: record(128), incoming: record(slowBpm, lengthMs: slowMixIn + 30_100, mixInMs: slowMixIn, mixOutMs: 120_000),
        bars: 8, outgoingStartMs: 221_250, incomingStartMs: 94_687.5, incomingRate: 1.01, total: 0.68
    ),
    .unremarkable(
        why: "half a second more record and it gets the sixteen",
        outgoing: record(128), incoming: record(slowBpm, lengthMs: slowMixIn + 30_600, mixInMs: slowMixIn, mixOutMs: 120_000),
        bars: 16, outgoingStartMs: 206_250, incomingStartMs: 94_687.5, incomingRate: 1.01, total: 0.68
    ),
    .unremarkable(
        why: "records that clash are capped at eight and get the filter fade",
        outgoing: record(128, key: "3B"), incoming: record(128, key: "10B"),
        bars: 8, outgoingStartMs: 221_250, incomingStartMs: 0, incomingRate: 1, total: 0.58, style: .filterFade
    ),
    .unremarkable(
        why: "neighbours are not capped, and the score decides on longer",
        outgoing: record(128, key: "8A"), incoming: record(128, key: "9A"),
        bars: 32, outgoingStartMs: 176_250, incomingStartMs: 0, incomingRate: 1, total: 0.78
    ),
    .unremarkable(
        why: "both ends are put on the grid, whatever the mix points say",
        outgoing: record(128, mixOutMs: 200_234), incoming: record(128, anchorMs: 100, mixInMs: 40_051),
        bars: 16, outgoingStartMs: 168_750, incomingStartMs: 39_475, incomingRate: 1, total: 0.68
    ),
    ParityCase(
        why: "an outgoing record that has not been read is not mixed",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: nil, incomingArrangement: plain,
        bars: nil
    ),
    ParityCase(
        why: "nor is an incoming one",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: plain, incomingArrangement: nil,
        bars: nil
    ),
    ParityCase(
        why: "matching tempo is not a substitute for knowing the arrangement",
        outgoing: grid(), incoming: grid(),
        bars: nil
    ),
    ParityCase(
        why: "a mix starts on the bar when the phrase line is more than two bars back",
        outgoing: grid(mixOutMs: bar * 115), incoming: grid(),
        outgoingArrangement: plain, incomingArrangement: plain,
        bars: 32, outgoingStartMs: 155_625, incomingStartMs: 0, incomingRate: 1, total: 0.7600000000000001
    ),
    ParityCase(
        why: "and comes in on one",
        outgoing: grid(), incoming: grid(mixInMs: bar * 11),
        outgoingArrangement: plain, incomingArrangement: plain,
        bars: 32, outgoingStartMs: 150_000, incomingStartMs: 0, incomingRate: 1, total: 0.7600000000000001
    ),
    ParityCase(
        why: "an entry a bar short of a phrase line moves forward onto it",
        outgoing: grid(), incoming: grid(mixInMs: bar * 15),
        outgoingArrangement: plain, incomingArrangement: plain,
        bars: 32, outgoingStartMs: 150_000, incomingStartMs: 30_000, incomingRate: 1, total: 0.8000000000000002
    ),
    ParityCase(
        why: "without a phrase grid, a bar line is the best there is",
        outgoing: grid(mixOutMs: bar * 115), incoming: grid(mixInMs: bar * 11),
        outgoingArrangement: noPhrases, incomingArrangement: noPhrases,
        bars: 32, outgoingStartMs: 155_625, incomingStartMs: 20_625, incomingRate: 1, total: 0.8000000000000002
    ),
    ParityCase(
        why: "two records singing at once is not a mix",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: singingOut, incomingArrangement: singingIn,
        bars: nil
    ),
    ParityCase(
        why: "one voice is fine, and gets the filter fade",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: singingOut, incomingArrangement: singsLater,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 15_000, incomingRate: 1, total: 0.665, style: .filterFade
    ),
    ParityCase(
        why: "not being able to tell counts as singing",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: cannotTell, incomingArrangement: singingIn,
        bars: nil
    ),
    ParityCase(
        why: "looked and found none is not the same as could not tell",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: cannotTell, incomingArrangement: instrumental,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 15_000, incomingRate: 1, total: 0.665, style: .filterFade
    ),
    ParityCase(
        why: "a drop onto a drop gets eight bars, not sixteen",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: dropOut, incomingArrangement: dropIn,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 15_000, incomingRate: 1, total: 0.7250000000000001
    ),
    ParityCase(
        why: "coming in on a build keeps the sixteen",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: dropOut, incomingArrangement: buildIn,
        bars: 16, outgoingStartMs: 180_000, incomingStartMs: 0, incomingRate: 1, total: 0.7250000000000001
    ),
    ParityCase(
        why: "a record comes in on its build when it has one",
        outgoing: grid(), incoming: grid(),
        outgoingArrangement: midEnergy, incomingArrangement: withBuild,
        bars: 32, outgoingStartMs: 150_000, incomingStartMs: 30_000, incomingRate: 1, total: 0.8900000000000001
    ),
    ParityCase(
        why: "everything right earns thirty-two",
        outgoing: grid(key: "9A"), incoming: grid(key: "8A"),
        outgoingArrangement: breakdownOut, incomingArrangement: withBuild,
        bars: 32, outgoingStartMs: 150_000, incomingStartMs: 30_000, incomingRate: 1, total: 0.92
    ),
    ParityCase(
        why: "compatible keys and nobody singing is a blend",
        outgoing: grid(key: "8A"), incoming: grid(key: "9A"),
        outgoingArrangement: buildThenDrop, incomingArrangement: buildThenDrop,
        bars: 32, outgoingStartMs: 150_000, incomingStartMs: 0, incomingRate: 1, total: 0.825
    ),
    ParityCase(
        why: "clashing keys are a capped filter fade",
        outgoing: grid(key: "3B"), incoming: grid(key: "10B"),
        outgoingArrangement: buildThenDrop, incomingArrangement: buildThenDrop,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 0, incomingRate: 1, total: 0.625, style: .filterFade
    ),
    ParityCase(
        why: "the outgoing record singing is a filter fade, capped at eight",
        outgoing: grid(key: "8A"), incoming: grid(key: "9A"),
        outgoingArrangement: singingThroughout, incomingArrangement: buildThenDrop,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 0, incomingRate: 1, total: 0.7649999999999999, style: .filterFade
    ),
    ParityCase(
        why: "and so is the incoming one",
        outgoing: grid(key: "8A"), incoming: grid(key: "9A"),
        outgoingArrangement: buildThenDrop, incomingArrangement: singingThroughout,
        bars: 8, outgoingStartMs: 195_000, incomingStartMs: 0, incomingRate: 1, total: 0.7649999999999999, style: .filterFade
    ),
    // The singing check covers exactly the stretch that would overlap, so the
    // score can change with the length; the planner gives up on an entry the
    // moment a length scores nothing rather than trying the shorter ones.
    // Thirty-two bars from bar 80 hears the voice and scores 0.315; sixteen
    // from bar 96 would not, and would have earned eight.
    ParityCase(
        why: "a score refused at thirty-two bars refuses the entry, though sixteen would have been clean",
        outgoing: grid(key: "3B"), incoming: record(128 / 1.03, key: "10B", mixInMs: bar * 8, mixOutMs: bar * 112),
        outgoingArrangement: singsAtEighty, incomingArrangement: quietDrop,
        bars: nil
    ),
]

@Suite("DJ planner parity")
struct DJPlannerParityTests {
    @Test("plans the desktop's table identically", arguments: parityTable)
    fileprivate func parityWithDesktop(_ row: ParityCase) {
        let plan = DJPlanner.plan(
            outgoing: row.outgoing,
            incoming: row.incoming,
            notBeforeMs: row.notBeforeMs,
            outgoingArrangement: row.outgoingArrangement,
            incomingArrangement: row.incomingArrangement
        )
        guard let bars = row.bars else {
            #expect(plan == nil)
            return
        }
        #expect(plan?.bars == bars)
        #expect(plan.map { abs($0.outgoingStartMs - row.outgoingStartMs) < 1e-9 } == true, "start \(plan?.outgoingStartMs ?? -1)")
        #expect(plan.map { abs($0.incomingStartMs - row.incomingStartMs) < 1e-9 } == true, "entry \(plan?.incomingStartMs ?? -1)")
        #expect(plan.map { abs($0.incomingRate - row.incomingRate) < 1e-12 } == true)
        #expect(plan.map { abs($0.score.total - row.total) < 1e-12 } == true, "total \(plan?.score.total ?? -1)")
        #expect(plan?.style == row.style)
        #expect(plan?.outgoingRate == 1)
        #expect(plan?.restoreSeconds == 8)
    }

    @Test("answers every case in the table")
    func everyCase() {
        #expect(parityTable.count == 41)
    }
}
