import Foundation
import Testing
@testable import PlaybackKit

/// What both apps read off an arrangement, and how both score a pair, with
/// the same answers.
///
/// Duplicated verbatim in the desktop's `arrangement-parity.test.ts`. The
/// score totals are exact doubles because the bar thresholds are inclusive,
/// and a total a rounding error under one on one app is a shorter mix on that
/// app.

private let bar = 60_000.0 / 128 * 4

/// Intro, drop, outro in bars, sung in the first two seconds.
private let record = Arrangement(
    sections: [
        Arrangement.Section(startMs: 0, endMs: bar * 16, kind: .intro, energy: 0.1),
        Arrangement.Section(startMs: bar * 16, endMs: bar * 112, kind: .drop, energy: 1),
        Arrangement.Section(startMs: bar * 112, endMs: bar * 128, kind: .outro, energy: 0.2),
    ],
    phraseBars: 16,
    phraseAnchorMs: 0,
    vocals: [Arrangement.Span(startMs: 1_000, endMs: 2_000)]
)

private func arrangement(vocals state: String) -> Arrangement {
    Arrangement(
        sections: record.sections,
        phraseBars: record.phraseBars,
        phraseAnchorMs: record.phraseAnchorMs,
        vocals: state == "found" ? record.vocals : state == "none" ? [] : nil
    )
}

private struct Singing: Sendable, CustomTestStringConvertible {
    let vocals: String
    let from: Double
    let to: Double
    let sings: Bool
    var testDescription: String { "vocals \(vocals), \(from)–\(to) ms: may sing \(sings)" }
}

private struct Phrase: Sendable, CustomTestStringConvertible {
    let phraseBars: Int?
    let anchorMs: Double?
    let ms: Double
    let barMs: Double
    let start: Double?
    var testDescription: String { "phrases of \(phraseBars.map(String.init) ?? "nil") at \(ms) ms" }
}

private struct SectionPair: Sendable, CustomTestStringConvertible {
    let exit: Arrangement.Kind?
    let entry: Arrangement.Kind?
    let factor: Double
    var testDescription: String { "out of \(exit.map(\.rawValue) ?? "nil") into \(entry.map(\.rawValue) ?? "nil")" }
}

private struct Total: Sendable, CustomTestStringConvertible {
    let tempo: Double
    let key: Double
    let vocals: Double
    let energy: Double
    let sections: Double
    let total: Double
    let bars: Int?
    var testDescription: String { "\(tempo) \(key) \(vocals) \(energy) \(sections) totals \(total)" }
}

/// `(ms, kind)`.
private let sectionLookups: [(Double, Arrangement.Kind?)] = [
    (0, .intro),
    (bar * 16 - 0.001, .intro),
    (bar * 16, .drop),
    (bar * 112, .outro),
    (bar * 200, .outro),
    (-1, nil),
]

private let singing: [Singing] = [
    Singing(vocals: "found", from: 500, to: 1_500, sings: true),
    Singing(vocals: "found", from: 1_500, to: 1_600, sings: true),
    Singing(vocals: "found", from: 2_000, to: 3_000, sings: false),
    Singing(vocals: "found", from: 0, to: 1_000, sings: false),
    Singing(vocals: "found", from: 0, to: 1_000.001, sings: true),
    Singing(vocals: "none", from: 0, to: 1_000_000, sings: false),
    Singing(vocals: "unknown", from: 100_000, to: 100_001, sings: true),
]

private let phrases: [Phrase] = [
    Phrase(phraseBars: 16, anchorMs: 0, ms: bar * 21, barMs: bar, start: bar * 16),
    Phrase(phraseBars: 16, anchorMs: 0, ms: bar * 16, barMs: bar, start: bar * 16),
    Phrase(phraseBars: 16, anchorMs: 0, ms: bar * 15.999, barMs: bar, start: 0),
    Phrase(phraseBars: 16, anchorMs: 100, ms: 100 + bar * 17, barMs: bar, start: 100 + bar * 16),
    Phrase(phraseBars: 16, anchorMs: 100, ms: 50, barMs: bar, start: 100 - bar * 16),
    Phrase(phraseBars: 8, anchorMs: 0, ms: bar * 21, barMs: bar, start: bar * 16),
    Phrase(phraseBars: 32, anchorMs: 0, ms: bar * 21, barMs: bar, start: 0),
    Phrase(phraseBars: nil, anchorMs: nil, ms: 10, barMs: bar, start: nil),
    Phrase(phraseBars: 16, anchorMs: nil, ms: 10, barMs: bar, start: nil),
    Phrase(phraseBars: 16, anchorMs: 0, ms: 10, barMs: 0, start: nil),
]

/// `(rate, tempo factor)`.
private let tempi: [(Double, Double)] = [
    (1, 1),
    (1.019, 1),
    (1.02, 1),
    (0.98, 1),
    (1.04, 0.5),
    (0.96, 0.5),
    (1.06, 0),
    (1.1, 0),
]

private let sectionPairs: [SectionPair] = [
    SectionPair(exit: .outro, entry: .build, factor: 1),
    SectionPair(exit: .breakdown, entry: .intro, factor: 1),
    SectionPair(exit: .drop, entry: .drop, factor: 0.3),
    SectionPair(exit: .drop, entry: .build, factor: 0.7),
    SectionPair(exit: .build, entry: .drop, factor: 0.45),
    SectionPair(exit: .intro, entry: .outro, factor: 0.7),
    SectionPair(exit: .verse, entry: .verse, factor: 0.7),
    SectionPair(exit: .chorus, entry: .chorus, factor: 0.7),
    SectionPair(exit: .unknown, entry: .unknown, factor: 0.6),
    SectionPair(exit: nil, entry: .build, factor: 0.5),
    SectionPair(exit: .outro, entry: nil, factor: 0.5),
]

private let totals: [Total] = [
    Total(tempo: 1, key: 1, vocals: 1, energy: 1, sections: 1, total: 1, bars: 32),
    Total(tempo: 1, key: 0.5, vocals: 0.5, energy: 0.5, sections: 0.5, total: 0.6000000000000001, bars: 16),
    Total(tempo: 0.4, key: 0, vocals: 0.5, energy: 0.5, sections: 0.5, total: 0.38, bars: 8),
    Total(tempo: 0, key: 0, vocals: 0.5, energy: 0, sections: 0.2, total: 0.125, bars: nil),
    Total(tempo: 1, key: 1, vocals: 0.5, energy: 0.5, sections: 0.7, total: 0.75, bars: 32),
    Total(tempo: 0.75, key: 0.5, vocals: 0.5, energy: 0.5, sections: 0.5, total: 0.55, bars: 16),
    Total(tempo: 0.7499, key: 0.5, vocals: 0.5, energy: 0.5, sections: 0.5, total: 0.54998, bars: 8),
    Total(tempo: 0, key: 0.5, vocals: 0.5, energy: 0.25, sections: 0.5, total: 0.35, bars: 8),
    Total(tempo: 0, key: 0.5, vocals: 0.5, energy: 0.2499, sections: 0.5, total: 0.34997999999999996, bars: nil),
]

@Suite("Arrangement parity")
struct ArrangementParityTests {
    @Test("finds the desktop's sections", arguments: sectionLookups)
    func section(_ row: (Double, Arrangement.Kind?)) {
        #expect(record.section(at: row.0)?.kind == row.1)
    }

    @Test("hears the desktop's singing", arguments: singing)
    fileprivate func sings(_ row: Singing) {
        #expect(arrangement(vocals: row.vocals).maySing(from: row.from, to: row.to) == row.sings)
    }

    @Test("counts the desktop's phrases", arguments: phrases)
    fileprivate func phrase(_ row: Phrase) {
        let arrangement = Arrangement(
            sections: record.sections, phraseBars: row.phraseBars, phraseAnchorMs: row.anchorMs, vocals: record.vocals
        )
        let found = arrangement.phraseStart(atOrBefore: row.ms, barMs: row.barMs)
        if let start = row.start {
            #expect(found.map { abs($0 - start) < 1e-9 } == true)
        } else {
            #expect(found == nil)
        }
    }

    @Test("scores the desktop's tempi", arguments: tempi)
    func tempo(_ row: (Double, Double)) {
        #expect(abs(MixScore.tempo(rate: row.0) - row.1) < 1e-12)
    }

    @Test("scores the desktop's section pairs", arguments: sectionPairs)
    fileprivate func sectionPair(_ row: SectionPair) {
        #expect(abs(MixScore.sections(exit: row.exit, entry: row.entry) - row.factor) < 1e-12)
    }

    @Test("the remaining factors")
    func factors() {
        #expect(MixScore.key("8A", "9A") == 1)
        #expect(MixScore.key("3B", "10B") == 0)
        #expect(MixScore.key(nil, "8A") == 0.5)
        #expect(MixScore.vocals(outgoingSings: false, incomingSings: false) == 1)
        #expect(MixScore.vocals(outgoingSings: true, incomingSings: false) == 0.6)
        #expect(MixScore.vocals(outgoingSings: nil, incomingSings: false) == 0.5)
        #expect(MixScore.energy(0.5, 0.5) == 1)
        #expect(abs(MixScore.energy(0.9, 0.2) - 0.3) < 1e-12)
        #expect(MixScore.energy(nil, 0.5) == 0.5)
    }

    @Test("totals and earns as the desktop does", arguments: totals)
    fileprivate func total(_ row: Total) {
        let score = MixScore(tempo: row.tempo, key: row.key, vocals: row.vocals, energy: row.energy, sections: row.sections)
        #expect(abs(score.total - row.total) < 1e-15)
        #expect(score.bars == row.bars)
    }

    @Test("answers every case in the tables")
    func everyCase() {
        #expect(sectionLookups.count == 6)
        #expect(singing.count == 7)
        #expect(phrases.count == 10)
        #expect(tempi.count == 8)
        #expect(sectionPairs.count == 11)
        #expect(totals.count == 9)
    }
}
