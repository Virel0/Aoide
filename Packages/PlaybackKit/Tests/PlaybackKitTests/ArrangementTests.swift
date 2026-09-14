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
    @Test("A mix starts on a phrase when one is close, and on the bar when it is not")
    func phraseAligned() throws {
        // A pair with everything going for it earns thirty-two bars. Mix-out at
        // bar 112; thirty-two back is bar 80, a phrase line. Move the mix-out to
        // bar 115 and thirty-two back is bar 83 — three bars past the phrase
        // line, further than the two the server itself allows a boundary to
        // move — so the start stays on bar 83 and the mix ends where the
        // record's mix-out says, not seven bars into it.
        let crooked = BeatGrid(
            segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0,
            mixInMs: bar * 8, mixOutMs: bar * 115
        )
        let plan = try #require(DJPlanner.plan(
            outgoing: crooked, incoming: grid(),
            outgoingArrangement: plain, incomingArrangement: plain
        ))
        #expect(plan.bars == 32)
        #expect(abs(plan.outgoingStartMs - bar * 83) < 0.01)

        // Two bars past a phrase line, the start does move onto it.
        let nearly = BeatGrid(
            segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0,
            mixInMs: bar * 8, mixOutMs: bar * 114
        )
        let snapped = try #require(DJPlanner.plan(
            outgoing: nearly, incoming: grid(),
            outgoingArrangement: plain, incomingArrangement: plain
        ))
        #expect(abs(snapped.outgoingStartMs - bar * 80) < 0.01)

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
        #expect(abs(barred.outgoingStartMs - bar * (115 - Double(barred.bars))) < 0.01)
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

    @Test("A record that has not been read is not mixed")
    func unreadIsRefused() {
        // Matching tempo is not a substitute for knowing the arrangement. Two
        // pop records with clashing keys and a voice on each were scoring eight
        // bars together on tempo and key alone — and eight bars of two singers
        // in two keys is not a mix by any definition.
        #expect(DJPlanner.plan(outgoing: grid(), incoming: grid()) == nil)
        #expect(DJPlanner.plan(outgoing: grid(), incoming: grid(), outgoingArrangement: plain) == nil)
        #expect(DJPlanner.plan(outgoing: grid(), incoming: grid(), incomingArrangement: plain) == nil)
    }

    @Test("Something to hide gets the filter fade; nothing to hide gets the blend")
    func styleFollowsTheClash() throws {
        let instrumental = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)])
        // Compatible keys, nobody singing: a blend.
        let agree = try #require(DJPlanner.plan(
            outgoing: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "8A"),
            incoming: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "9A"),
            outgoingArrangement: instrumental, incomingArrangement: instrumental
        ))
        #expect(agree.style == .blend)

        // Clashing keys: the outgoing record's melody has to be gone before the
        // two overlap in earnest.
        let clash = try #require(DJPlanner.plan(
            outgoing: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "3B"),
            incoming: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "10B"),
            outgoingArrangement: instrumental, incomingArrangement: instrumental
        ))
        #expect(clash.style == .filterFade)

        // One of them singing, keys fine: also the filter fade — the voice is
        // the thing to keep out from under the other record.
        let singing = arrangement([(.build, 32, 0.4), (.drop, 96, 0.9)], vocals: [.init(startMs: 0, endMs: bar * 128)])
        let voice = try #require(DJPlanner.plan(
            outgoing: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "8A"),
            incoming: BeatGrid(segments: grid().segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: bar * 8, mixOutMs: bar * 112, key: "9A"),
            outgoingArrangement: singing, incomingArrangement: instrumental
        ))
        #expect(voice.style == .filterFade)
    }

    @Test("The filter fade takes the outgoing record's middle away before the swap")
    func filterFadeSweeps() {
        // Open at the start; up to the fade's corner by the swap; held there.
        #expect(DJAutomation.outgoingHighPassHz(progress: 0, style: .filterFade) == DJAutomation.openHz)
        #expect(abs(DJAutomation.outgoingHighPassHz(progress: 0.5, style: .filterFade) - DJAutomation.filterFadeHz) < 0.01)
        #expect(abs(DJAutomation.outgoingHighPassHz(progress: 0.9, style: .filterFade) - DJAutomation.filterFadeHz) < 0.01)
        // Halfway there in octaves, not in hertz: 20 → 1,500 passes 173, not 760.
        #expect(abs(DJAutomation.outgoingHighPassHz(progress: 0.25, style: .filterFade) - (20 * 1_500).squareRoot()) < 0.5)

        // A blend leaves the record alone until the swap.
        #expect(DJAutomation.outgoingHighPassHz(progress: 0.4, style: .blend) == DJAutomation.openHz)
        #expect(abs(DJAutomation.outgoingHighPassHz(progress: 0.9, style: .blend) - DJAutomation.bassCutHz) < 0.01)
        // And the incoming record comes in without its bass either way.
        #expect(abs(DJAutomation.incomingHighPassHz(progress: 0.1) - DJAutomation.bassCutHz) < 0.01)
        #expect(DJAutomation.incomingHighPassHz(progress: 0.9) == DJAutomation.openHz)
    }

    @Test("A record comes in on its build when it has one")
    func comesInOnTheBuild() throws {
        // Mix-in at bar 8, inside the intro; a build from bar 16. A DJ brings the
        // record in on the build, and so does this.
        let withBuild = arrangement([(.intro, 16, 0.2), (.build, 16, 0.5), (.drop, 80, 0.95), (.outro, 16, 0.2)])
        let outgoingSide = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.55), (.outro, 16, 0.2)])
        let plan = try #require(DJPlanner.plan(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: outgoingSide, incomingArrangement: withBuild
        ))
        #expect(abs(plan.incomingStartMs - bar * 16) < 0.01)
        #expect(plan.score.sections == 1)
    }

    @Test("Energy that matches scores; energy that does not, does not")
    func energyCounts() {
        #expect(MixScore.energy(0.5, 0.5) == 1)
        #expect(abs(MixScore.energy(0.9, 0.2) - 0.3) < 1e-9)
        #expect(MixScore.energy(nil, 0.5) == 0.5)
    }

    @Test("The score sets the length")
    func scoreSetsLength() {
        let perfect = MixScore(tempo: 1, key: 1, vocals: 1, energy: 1, sections: 1)
        #expect(perfect.bars == 32)
        let unknown = MixScore(tempo: 1, key: 0.5, vocals: 0.5, energy: 0.5, sections: 0.5)
        #expect(unknown.bars == 16)
        let strained = MixScore(tempo: 0.4, key: 0, vocals: 0.5, energy: 0.5, sections: 0.5)
        #expect(strained.bars == 8)
        let hopeless = MixScore(tempo: 0, key: 0, vocals: 0.5, energy: 0, sections: 0.2)
        #expect(hopeless.bars == nil)
        // Two per cent is free; six is the end of the road.
        #expect(MixScore.tempo(rate: 1.019) == 1)
        #expect(abs(MixScore.tempo(rate: 1.04) - 0.5) < 1e-9)
        #expect(MixScore.tempo(rate: 1.06) == 0)
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

@Suite("Cuts and echo-outs")
struct CutTests {
    private let read = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)])

    private let slow = BeatGrid(
        segments: [BeatGrid.Segment(startMs: 0, endMs: 240_000, anchorMs: 0, bpm: 100, residualMs: 4, beats: 400)],
        beatsPerBar: 4, downbeatIndex: 0, mixInMs: 2_400 * 8, mixOutMs: 2_400 * 90
    )

    @Test("A cut lands on a line nobody is singing across")
    func cutClearOfTheWords() throws {
        // Somebody singing right across the line at bar 112 — from a bar
        // before it to a bar after — and again across the one at bar 96.
        // The line at bar 80 has a rest before it.
        let sung = arrangement(
            [(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)],
            vocals: [
                .init(startMs: bar * 20, endMs: bar * 79.5),
                .init(startMs: bar * 95, endMs: bar * 97),
                .init(startMs: bar * 111, endMs: bar * 113),
            ]
        )
        let cut = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: sung, incomingArrangement: read))
        #expect(abs(cut.outgoingStartMs - bar * 80) < 0.01, "cut at bar \(cut.outgoingStartMs / bar)")

        // A rest of less than a syllable before the line is not a rest.
        let barely = arrangement(
            [(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)],
            vocals: [.init(startMs: bar * 97, endMs: bar * 112 - 130)]
        )
        let late = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: barely, incomingArrangement: read))
        #expect(abs(late.outgoingStartMs - bar * 96) < 0.01, "cut at bar \(late.outgoingStartMs / bar)")
        let rested = arrangement(
            [(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)],
            vocals: [.init(startMs: bar * 97, endMs: bar * 112 - 151)]
        )
        let onTime = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: rested, incomingArrangement: read))
        #expect(abs(onTime.outgoingStartMs - bar * 112) < 0.01)

        // Singing across every line in reach: the line stands where it was,
        // because four phrases back is a different part of the record.
        let throughout = arrangement(
            [(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)],
            vocals: [.init(startMs: bar * 20, endMs: bar * 120)]
        )
        let stands = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: throughout, incomingArrangement: read))
        #expect(abs(stands.outgoingStartMs - bar * 112) < 0.01)

        // The search stays inside the part the exit is in. Here the hook
        // runs from bar 80 to 112 and is sung across every line in it, and
        // the breath before it — the rest before bar 80 — is the cleanest
        // rest in the record. Cutting there would leave on the brink of the
        // chorus, so the line stands at the hook's end instead.
        let hook = arrangement(
            [(.intro, 16, 0.2), (.build, 64, 0.5), (.drop, 32, 0.95), (.outro, 16, 0.2)],
            vocals: [
                .init(startMs: bar * 20, endMs: bar * 78),
                .init(startMs: bar * 80.5, endMs: bar * 113),
            ]
        )
        let held = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: hook, incomingArrangement: read))
        #expect(abs(held.outgoingStartMs - bar * 112) < 0.01, "cut at bar \(held.outgoingStartMs / bar)")
        // Whereas a rest inside the hook — after its first phrase — is taken.
        let breath = arrangement(
            [(.intro, 16, 0.2), (.build, 64, 0.5), (.drop, 32, 0.95), (.outro, 16, 0.2)],
            vocals: [
                .init(startMs: bar * 20, endMs: bar * 78),
                .init(startMs: bar * 80.5, endMs: bar * 95),
                .init(startMs: bar * 97, endMs: bar * 113),
            ]
        )
        let inside = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: breath, incomingArrangement: read))
        #expect(abs(inside.outgoingStartMs - bar * 96) < 0.01, "cut at bar \(inside.outgoingStartMs / bar)")

        // Vocals unknown: nothing to go on, and the line stands.
        let unknown = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: nil)
        let asGiven = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: unknown, incomingArrangement: read))
        #expect(abs(asGiven.outgoingStartMs - bar * 112) < 0.01)
    }

    @Test("A pair that cannot be bent is cut on the phrase line, not blended")
    func cutWhenUnbendable() throws {
        // 100 into 128 is not a bend anybody makes.
        let slow = BeatGrid(
            segments: [BeatGrid.Segment(startMs: 0, endMs: 240_000, anchorMs: 0, bpm: 100, residualMs: 4, beats: 400)],
            beatsPerBar: 4, downbeatIndex: 0, mixInMs: 2_400 * 8, mixOutMs: 2_400 * 90
        )
        #expect(DJPlanner.plan(outgoing: grid(), incoming: slow, outgoingArrangement: read, incomingArrangement: read) == nil)

        let cut = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: read, incomingArrangement: read
        ))
        #expect(cut.bars == 0)
        #expect(cut.seconds == 0)
        #expect(!cut.style.overlaps)
        // On the phrase line at the outgoing record's mix-out, bar 112.
        #expect(abs(cut.outgoingStartMs - bar * 112) < 0.01)
        // And the new record is not bent to a tempo nothing is running beside.
        #expect(cut.incomingRate == 1)
    }

    @Test("Out of something loud into something quiet, the last beat rings")
    func echoWhenDropping() throws {
        let loud = arrangement([(.intro, 16, 0.2), (.drop, 112, 1.0)])
        let quiet = arrangement([(.intro, 32, 0.2), (.drop, 96, 0.9)])
        let echo = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: grid(mixInMs: bar * 8),
            outgoingArrangement: loud, incomingArrangement: quiet
        ))
        #expect(echo.style == .echoOut)

        // Level into level too: a dead cut was the harshest thing the set
        // did, and nothing plans one now.
        let level = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: grid(),
            outgoingArrangement: read, incomingArrangement: read
        ))
        #expect(level.style == .echoOut)
    }

    @Test("A pair that has not been read is not cut either")
    func unreadIsNotCut() {
        #expect(DJPlanner.planCut(outgoing: grid(), incoming: grid(), outgoingArrangement: nil, incomingArrangement: read) == nil)
    }
}

@Suite("Lyrics as the map for a cut")
struct LyricCutTests {
    private let read = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)])
    private let slow = BeatGrid(
        segments: [BeatGrid.Segment(startMs: 0, endMs: 240_000, anchorMs: 0, bpm: 100, residualMs: 4, beats: 400)],
        beatsPerBar: 4, downbeatIndex: 0, mixInMs: 2_400 * 8, mixOutMs: 2_400 * 90
    )

    @Test("A moment is clean before a line starts, in a rest, or after the last line")
    func cleanMoments() {
        let lines: [Double] = [10_000, 13_000, 16_000, 30_000, 33_000]
        let beat = 60_000.0 / 128 // 469 ms: the lead is the 600 ms floor
        // 12.5 s: 500 ms before a line starts — the previous one is over.
        #expect(Arrangement.isLyricClean(12_500, lineStartsMs: lines, beatMs: beat))
        // 12.2 s: 800 ms before a line, 2.2 s into the previous — mid-line.
        #expect(!Arrangement.isLyricClean(12_200, lineStartsMs: lines, beatMs: beat))
        // At 100 BPM the beat is 600 ms too; at 60 it is a second, and 12.2
        // is inside it.
        #expect(Arrangement.isLyricClean(12_200, lineStartsMs: lines, beatMs: 1_000))
        // 11 s: a second into a line.
        #expect(!Arrangement.isLyricClean(11_000, lineStartsMs: lines, beatMs: beat))
        // 25 s: nine seconds after a line started, with the next at 30 —
        // a rest longer than any line runs.
        #expect(Arrangement.isLyricClean(25_000, lineStartsMs: lines, beatMs: beat))
        // 20 s: four seconds in, next at 30 — still within a line's reach.
        #expect(!Arrangement.isLyricClean(20_000, lineStartsMs: lines, beatMs: beat))
        // 9 s: before the first line ever starts.
        #expect(Arrangement.isLyricClean(9_000, lineStartsMs: lines, beatMs: beat))
        // 45 s: long after the last.
        #expect(Arrangement.isLyricClean(45_000, lineStartsMs: lines, beatMs: beat))
        // No lyrics at all: nothing to say.
        #expect(Arrangement.isLyricClean(20_000, lineStartsMs: [], beatMs: beat))
    }

    @Test("No clean word in reach is a filtered cut, not an echo of a bad one")
    func noCleanWordNoEcho() throws {
        let sung = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [])
        // A line starting 900 ms after every other bar: the one before each
        // phrase line is still running and the next starts too late — past
        // the beat's lead — to count as the line's end. Mid-line, on every
        // line in reach.
        let lines = stride(from: 0.0, through: bar * 128, by: bar * 2).map { $0 + 900 }
        let cut = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: sung, incomingArrangement: read,
            outgoingLyricLinesMs: lines
        ))
        #expect(cut.style == .cut)
        // The same record with a rest before the line at bar 112: a throw.
        let clean = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: sung, incomingArrangement: read,
            outgoingLyricLinesMs: [bar * 100, bar * 112 + 300]
        ))
        #expect(clean.style == .echoOut)
        // No lyrics: a throw, whatever the spans say — they are too coarse
        // to refuse on. They still place the line.
        let bySpans = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: sung, incomingArrangement: read))
        #expect(bySpans.style == .echoOut)
        let throughout = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [.init(startMs: 0, endMs: bar * 128)])
        let sungThrough = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: throughout, incomingArrangement: read))
        #expect(sungThrough.style == .echoOut)
        let unknown = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: nil)
        let guess = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: unknown, incomingArrangement: read))
        #expect(guess.style == .echoOut)
    }

    @Test("The new record lands on its first line when that is near its start")
    func landmarkEntry() throws {
        let sung = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [])
        // The incoming record's mix-in is bar 8; its first line starts a
        // few hundred milliseconds after bar 12. It lands on bar 12.
        let entered = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: sung, incomingArrangement: read,
            incomingLyricLinesMs: [2_400 * 12 + 300, 2_400 * 20]
        ))
        #expect(abs(entered.incomingStartMs - 2_400 * 12) < 0.01, "entered at \(entered.incomingStartMs / 2_400)")
        // A first line forty bars in is not a landmark; the mix-in stands.
        let late = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: sung, incomingArrangement: read,
            incomingLyricLinesMs: [2_400 * 48]
        ))
        #expect(abs(late.incomingStartMs - 2_400 * 8) < 0.01)
        // No lyrics: the mix-in, phrase-snapped, as before.
        let plain = try #require(DJPlanner.planCut(outgoing: grid(), incoming: slow, outgoingArrangement: sung, incomingArrangement: read))
        #expect(abs(plain.incomingStartMs - 2_400 * 8) < 0.01)
    }

    @Test("With lyrics, a cut moves back to a line that is not mid-line; the spans are not consulted")
    func lyricsDecide() throws {
        // The spans say the phrase line at bar 112 is clear; the lyrics say a
        // line started three seconds before it and the next starts two
        // seconds after — mid-line. The line at bar 96 has a line starting
        // 200 ms after it: clean.
        let sung = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [])
        let lines: [Double] = [bar * 96 + 200, bar * 112 - 3_000, bar * 112 + 2_000]
        let cut = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: sung, incomingArrangement: read,
            outgoingLyricLinesMs: lines
        ))
        #expect(abs(cut.outgoingStartMs - bar * 96) < 0.01, "cut at bar \(cut.outgoingStartMs / bar)")

        // The other way round: the spans say sung throughout, the lyrics say
        // the line at bar 112 falls 300 ms before a line starts. Clean.
        let spansSay = arrangement([(.intro, 16, 0.2), (.drop, 96, 0.9), (.outro, 16, 0.2)], vocals: [.init(startMs: 0, endMs: bar * 128)])
        let clean = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: spansSay, incomingArrangement: read,
            outgoingLyricLinesMs: [bar * 100, bar * 112 + 300]
        ))
        #expect(abs(clean.outgoingStartMs - bar * 112) < 0.01, "cut at bar \(clean.outgoingStartMs / bar)")

        // Without lyrics, the spans decide as before.
        let byTheSpans = try #require(DJPlanner.planCut(
            outgoing: grid(), incoming: slow,
            outgoingArrangement: spansSay, incomingArrangement: read
        ))
        #expect(abs(byTheSpans.outgoingStartMs - bar * 112) < 0.01)
    }
}
