import Foundation
import Testing
@testable import PlaybackKit

/// The rig's own fixture, as the sidecar reported it: a twenty-second pad, then
/// 160 seconds of 128 BPM with the first beat at 20.000s, in A minor.
private let steady = BeatGrid(
    segments: [
        BeatGrid.Segment(startMs: 0, endMs: 180_000, anchorMs: 19_994.5, bpm: 128, residualMs: 4.8, beats: 345)
    ],
    beatsPerBar: 4,
    downbeatIndex: 0,
    mixInMs: 19_994.5,
    mixOutMs: 179_369.5,
    key: "8A",
    keyConfidence: 1.0
)

/// The drifting fixture: 105→145 BPM, which comes back as segments with large
/// residuals, no meter and no mix points.
private let drifting = BeatGrid(
    segments: [
        BeatGrid.Segment(startMs: 0, endMs: 30_000, anchorMs: 120, bpm: 105, residualMs: 261, beats: 52),
        BeatGrid.Segment(startMs: 30_000, endMs: 60_000, anchorMs: 30_100, bpm: 118, residualMs: 57, beats: 59),
        BeatGrid.Segment(startMs: 60_000, endMs: 120_000, anchorMs: 60_050, bpm: 138, residualMs: 18, beats: 138),
    ],
    beatsPerBar: nil,
    downbeatIndex: nil
)

@Suite("Beat grid")
struct BeatGridTests {
    @Test("Beats fall where the fit says")
    func beats() throws {
        let segment = try #require(steady.segments.first)
        #expect(abs(segment.beat(0) - 19_994.5) < 0.001)
        // 128 BPM is 468.75ms a beat.
        #expect(abs(segment.beat(1) - segment.beat(0) - 468.75) < 0.001)
        #expect(abs(segment.beat(8) - (19_994.5 + 8 * 468.75)) < 0.001)
        #expect(segment.beatIndex(at: 19_994.5 + 468.75 * 3 + 10) == 3)
    }

    @Test("Bars are four beats, and every downbeat is a whole number of them from the anchor")
    func bars() throws {
        let barMs = try #require(steady.barMs(at: 60_000))
        #expect(abs(barMs - 468.75 * 4) < 0.001)

        let downbeat = try #require(steady.downbeat(atOrBefore: 60_000))
        let barsIn = (downbeat - 19_994.5) / barMs
        #expect(abs(barsIn - barsIn.rounded()) < 1e-9)
        #expect(downbeat <= 60_000)
        #expect(downbeat + barMs > 60_000)
    }

    @Test("A moment before the first beat still belongs to a segment")
    func beforeTheFirstBeat() {
        #expect(steady.segment(at: 500) != nil)
        // The pad is inside the segment, so the downbeat maths still answers —
        // negative bars are bars.
        #expect(steady.downbeat(atOrBefore: 500) != nil)
    }

    @Test("A tight grid may be locked to, a drifting one may not")
    func locking() {
        #expect(steady.canLock(at: 60_000, blendSeconds: 30))
        #expect(!drifting.canLock(at: 5_000, blendSeconds: 30))
        // Even the drifting fixture's best segment is refused, because its meter
        // was never established.
        #expect(!drifting.canLock(at: 70_000, blendSeconds: 8))
    }

    @Test("A shorter blend forgives a looser grid, up to a point")
    func toleranceScales() {
        #expect(BeatGrid.maximumResidualMs(forBlendSeconds: 30) == 20)
        #expect(BeatGrid.maximumResidualMs(forBlendSeconds: 15) == 40)
        // Capped: a two-bar blend does not accept a grid that is nonsense.
        #expect(BeatGrid.maximumResidualMs(forBlendSeconds: 4) == 40)
        #expect(BeatGrid.maximumResidualMs(forBlendSeconds: 0) == 0)
    }

    @Test("A blend may not cross a tempo change")
    func blendStaysInsideItsSegment() {
        let twoSegments = BeatGrid(
            segments: [
                BeatGrid.Segment(startMs: 0, endMs: 60_000, anchorMs: 0, bpm: 128, residualMs: 4, beats: 128),
                BeatGrid.Segment(startMs: 60_000, endMs: 120_000, anchorMs: 60_000, bpm: 140, residualMs: 4, beats: 140),
            ],
            beatsPerBar: 4,
            downbeatIndex: 0
        )
        #expect(twoSegments.canLock(at: 20_000, blendSeconds: 30))
        // Starting 20s before the change, a 30s blend would finish on the other
        // side of it.
        #expect(!twoSegments.canLock(at: 40_000, blendSeconds: 30))
    }

    @Test("No meter means nothing bar-aligned is offered")
    func noMeter() {
        let gridless = BeatGrid(segments: steady.segments, beatsPerBar: nil, downbeatIndex: nil)
        #expect(gridless.barMs(at: 60_000) == nil)
        #expect(gridless.downbeat(atOrBefore: 60_000) == nil)
        #expect(!gridless.canLock(at: 60_000, blendSeconds: 8))
    }

    @Test("A track with no grid at all refuses everything")
    func empty() {
        let nothing = BeatGrid(segments: [])
        #expect(nothing.segment(at: 0) == nil)
        #expect(!nothing.canLock(at: 0, blendSeconds: 8))
    }
}

@Suite("Camelot keys")
struct CamelotKeyTests {
    @Test("Reads the wheel")
    func parsing() throws {
        let aMinor = try #require(CamelotKey.parse("8A"))
        #expect(aMinor.number == 8)
        #expect(aMinor.isMinor)
        let cMajor = try #require(CamelotKey.parse("8B"))
        #expect(!cMajor.isMinor)
        #expect(CamelotKey.parse("12A")?.number == 12)
        #expect(CamelotKey.parse(nil) == nil)
        #expect(CamelotKey.parse("13A") == nil)
        #expect(CamelotKey.parse("0B") == nil)
        #expect(CamelotKey.parse("8C") == nil)
        #expect(CamelotKey.parse("Am") == nil)
    }

    @Test("The compatible moves are the neighbours and the relative")
    func compatibility() {
        #expect(CamelotKey.areCompatible("8A", "8A"))
        #expect(CamelotKey.areCompatible("8A", "9A"))
        #expect(CamelotKey.areCompatible("8A", "7A"))
        // The same number in the other letter — A minor and C major.
        #expect(CamelotKey.areCompatible("8A", "8B"))
        // Two steps is not a move.
        #expect(!CamelotKey.areCompatible("8A", "10A"))
        // Neighbouring numbers in different letters are not either.
        #expect(!CamelotKey.areCompatible("8A", "9B"))
        // The wheel wraps.
        #expect(CamelotKey.areCompatible("12A", "1A"))
        #expect(CamelotKey.areCompatible("1B", "12B"))
        #expect(!CamelotKey.areCompatible(nil, "8A"))
    }
}
