import Foundation
import Testing
@testable import PlaybackKit

/// The grid arithmetic both apps do, on the rig's two fixtures, with the same
/// answers.
///
/// Duplicated verbatim in the desktop's `beat-grid-parity.test.ts`, so either
/// side changing a rounding, a boundary or a tolerance breaks its own copy. A
/// downbeat a bar out on one app is a mix a bar out on that app, so the
/// downbeats are exact milliseconds and the locks are yes or no.

/// The rig's steady fixture: a twenty-second pad, then 128 BPM from 19.9945 s.
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

/// The drifting fixture: three fits, large residuals, no meter.
private let drifting = BeatGrid(
    segments: [
        BeatGrid.Segment(startMs: 0, endMs: 30_000, anchorMs: 120, bpm: 105, residualMs: 261, beats: 52),
        BeatGrid.Segment(startMs: 30_000, endMs: 60_000, anchorMs: 30_100, bpm: 118, residualMs: 57, beats: 59),
        BeatGrid.Segment(startMs: 60_000, endMs: 120_000, anchorMs: 60_050, bpm: 138, residualMs: 18, beats: 138),
    ],
    beatsPerBar: nil,
    downbeatIndex: nil
)

/// Two tempi, tight fits, a meter.
private let twoSegments = BeatGrid(
    segments: [
        BeatGrid.Segment(startMs: 0, endMs: 60_000, anchorMs: 0, bpm: 128, residualMs: 4, beats: 128),
        BeatGrid.Segment(startMs: 60_000, endMs: 120_000, anchorMs: 60_000, bpm: 140, residualMs: 4, beats: 140),
    ],
    beatsPerBar: 4,
    downbeatIndex: 0
)

/// A waltz on the steady fixture's fit.
private let waltz = BeatGrid(
    segments: steady.segments, beatsPerBar: 3, downbeatIndex: 0,
    mixInMs: steady.mixInMs, mixOutMs: steady.mixOutMs, key: steady.key, keyConfidence: steady.keyConfidence
)

private func grid(_ name: String) -> BeatGrid {
    switch name {
    case "steady": steady
    case "drifting": drifting
    case "twoSegments": twoSegments
    default: waltz
    }
}

private struct Lookup: Sendable, CustomTestStringConvertible {
    let grid: String
    let ms: Double
    let bpm: Double?
    let barMs: Double?
    let downbeat: Double?
    var testDescription: String { "\(grid) at \(ms) ms" }
}

private struct Lock: Sendable, CustomTestStringConvertible {
    let grid: String
    let ms: Double
    let seconds: Double
    let locks: Bool
    var testDescription: String { "\(grid) at \(ms) ms may lock a \(seconds)s blend: \(locks)" }
}

private struct Key: Sendable, CustomTestStringConvertible {
    let key: String?
    let number: Int?
    let minor: Bool
    var testDescription: String { "\(key ?? "nil") parses as \(number.map(String.init) ?? "nil")" }
}

private struct Move: Sendable, CustomTestStringConvertible {
    let a: String?
    let b: String?
    let compatible: Bool
    var testDescription: String { "\(a ?? "nil") and \(b ?? "nil") are compatible: \(compatible)" }
}

private let lookups: [Lookup] = [
    Lookup(grid: "steady", ms: 60_000, bpm: 128, barMs: 1875, downbeat: 59_369.5),
    Lookup(grid: "steady", ms: 19_994.5, bpm: 128, barMs: 1875, downbeat: 19_994.5),
    Lookup(grid: "steady", ms: 19_994.4, bpm: 128, barMs: 1875, downbeat: 18_119.5),
    Lookup(grid: "steady", ms: 500, bpm: 128, barMs: 1875, downbeat: -630.5),
    Lookup(grid: "steady", ms: 500_000, bpm: 128, barMs: 1875, downbeat: 499_994.5),
    Lookup(grid: "waltz", ms: 61_000, bpm: 128, barMs: 1406.25, downbeat: 60_775.75),
    Lookup(grid: "drifting", ms: 45_000, bpm: 118, barMs: nil, downbeat: nil),
    Lookup(grid: "drifting", ms: 30_000, bpm: 118, barMs: nil, downbeat: nil),
    Lookup(grid: "drifting", ms: 29_999.9, bpm: 105, barMs: nil, downbeat: nil),
    Lookup(grid: "drifting", ms: 500_000, bpm: 138, barMs: nil, downbeat: nil),
    Lookup(grid: "drifting", ms: -5, bpm: 105, barMs: nil, downbeat: nil),
    Lookup(grid: "twoSegments", ms: 59_999, bpm: 128, barMs: 1875, downbeat: 58_125),
    Lookup(grid: "twoSegments", ms: 60_000, bpm: 140, barMs: 1714.2857142857142, downbeat: 60_000),
    Lookup(grid: "twoSegments", ms: 100_000, bpm: 140, barMs: 1714.2857142857142, downbeat: 99_428.57142857143),
]

private let locks: [Lock] = [
    Lock(grid: "steady", ms: 60_000, seconds: 30, locks: true),
    Lock(grid: "steady", ms: 60_000, seconds: 60, locks: true),
    Lock(grid: "steady", ms: 150_001, seconds: 30, locks: false),
    Lock(grid: "steady", ms: 150_000, seconds: 30, locks: true),
    Lock(grid: "drifting", ms: 5_000, seconds: 30, locks: false),
    Lock(grid: "drifting", ms: 70_000, seconds: 8, locks: false),
    Lock(grid: "twoSegments", ms: 20_000, seconds: 30, locks: true),
    Lock(grid: "twoSegments", ms: 30_000, seconds: 30, locks: true),
    Lock(grid: "twoSegments", ms: 40_000, seconds: 30, locks: false),
    Lock(grid: "twoSegments", ms: 60_000, seconds: 30, locks: true),
]

/// `(blend seconds, maximum residual ms)`.
private let residuals: [(Double, Double)] = [
    (30, 20),
    (15, 40),
    (4, 40),
    (60, 10),
    (0, 0),
    (-1, 0),
]

private let keys: [Key] = [
    Key(key: "8A", number: 8, minor: true),
    Key(key: "8B", number: 8, minor: false),
    Key(key: "8b", number: 8, minor: false),
    Key(key: "12A", number: 12, minor: true),
    Key(key: "1B", number: 1, minor: false),
    Key(key: nil, number: nil, minor: false),
    Key(key: "", number: nil, minor: false),
    Key(key: "A", number: nil, minor: false),
    Key(key: "13A", number: nil, minor: false),
    Key(key: "0B", number: nil, minor: false),
    Key(key: "8C", number: nil, minor: false),
    Key(key: "Am", number: nil, minor: false),
    Key(key: "8.5A", number: nil, minor: false),
]

private let moves: [Move] = [
    Move(a: "8A", b: "8A", compatible: true),
    Move(a: "8A", b: "9A", compatible: true),
    Move(a: "8A", b: "7A", compatible: true),
    Move(a: "8A", b: "8B", compatible: true),
    Move(a: "8A", b: "10A", compatible: false),
    Move(a: "8A", b: "9B", compatible: false),
    Move(a: "12A", b: "1A", compatible: true),
    Move(a: "1B", b: "12B", compatible: true),
    Move(a: "1B", b: "11B", compatible: false),
    Move(a: nil, b: "8A", compatible: false),
    Move(a: "8A", b: "Am", compatible: false),
]

@Suite("Beat grid parity")
struct BeatGridParityTests {
    @Test("looks up the desktop's table identically", arguments: lookups)
    fileprivate func lookup(_ row: Lookup) {
        let grid = grid(row.grid)
        #expect(grid.segment(at: row.ms)?.bpm == row.bpm)
        if let barMs = row.barMs {
            #expect(grid.barMs(at: row.ms).map { abs($0 - barMs) < 1e-9 } == true)
        } else {
            #expect(grid.barMs(at: row.ms) == nil)
        }
        if let downbeat = row.downbeat {
            #expect(grid.downbeat(atOrBefore: row.ms).map { abs($0 - downbeat) < 1e-9 } == true)
        } else {
            #expect(grid.downbeat(atOrBefore: row.ms) == nil)
        }
    }

    @Test("locks the desktop's table identically", arguments: locks)
    fileprivate func lock(_ row: Lock) {
        #expect(grid(row.grid).canLock(at: row.ms, blendSeconds: row.seconds) == row.locks)
    }

    @Test("forgives the desktop's residuals identically", arguments: residuals)
    func residual(_ row: (Double, Double)) {
        #expect(BeatGrid.maximumResidualMs(forBlendSeconds: row.0) == row.1)
    }

    @Test("reads the desktop's keys identically", arguments: keys)
    fileprivate func key(_ row: Key) {
        let parsed = CamelotKey.parse(row.key)
        #expect(parsed?.number == row.number)
        if row.number != nil {
            #expect(parsed?.isMinor == row.minor)
        }
    }

    @Test("makes the desktop's moves identically", arguments: moves)
    fileprivate func move(_ row: Move) {
        #expect(CamelotKey.areCompatible(row.a, row.b) == row.compatible)
    }

    @Test("answers every case in the tables")
    func everyCase() {
        #expect(lookups.count == 14)
        #expect(locks.count == 10)
        #expect(residuals.count == 6)
        #expect(keys.count == 13)
        #expect(moves.count == 11)
    }
}
