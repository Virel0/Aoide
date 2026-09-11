import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The same sixteen instants of a mix on both apps, and what each fader and
/// filter is doing at each.
///
/// Duplicated verbatim in the desktop's `dj-automation-parity.test.ts`. Both
/// sides read `(progress, outgoing gain, incoming gain, outgoing cut, incoming
/// cut, outgoing bass dB, incoming bass dB, outgoing corner Hz for a blend,
/// outgoing corner Hz for a filter fade, incoming corner Hz)`. The corners
/// here are read back off ``DJMixer``'s high-pass after the automation has
/// set it, in the mixer's own single precision, so the sweep is the sweep a
/// listener gets.
private struct Instant: Sendable, CustomTestStringConvertible {
    let progress: Double
    let outgoingGain: Double
    let incomingGain: Double
    let outgoingCut: Double
    let incomingCut: Double
    let outgoingDb: Double
    let incomingDb: Double
    let blendHz: Double
    let fadeHz: Double
    let incomingHz: Double
    var testDescription: String { "at progress \(progress)" }
}

private let table: [Instant] = [
    Instant(progress: -1, outgoingGain: 1, incomingGain: 0, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 20, incomingHz: 220),
    Instant(progress: 0, outgoingGain: 1, incomingGain: 0, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 20, incomingHz: 220),
    Instant(progress: 0.05, outgoingGain: 1, incomingGain: 0.15643446504023087, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 30.79896498117631, incomingHz: 220),
    Instant(progress: 0.1, outgoingGain: 1, incomingGain: 0.3090169943749474, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 47.42881219558623, incomingHz: 220),
    Instant(progress: 0.25, outgoingGain: 1, incomingGain: 0.7071067811865475, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 173.20508075688775, incomingHz: 220),
    Instant(progress: 0.46, outgoingGain: 1, incomingGain: 0.9921147013144779, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 1061.906692749479, incomingHz: 220),
    Instant(progress: 0.48, outgoingGain: 1, incomingGain: 0.9980267284282716, outgoingCut: 0.25, incomingCut: 0.75, outgoingDb: -0.6876930815810842, incomingDb: -8.343206788338364, blendHz: 36.423205736757396, fadeHz: 1262.085591045321, incomingHz: 120.80210709074485),
    Instant(progress: 0.5, outgoingGain: 1, incomingGain: 1, outgoingCut: 0.5, incomingCut: 0.5, outgoingDb: -3.0102999566398085, incomingDb: -3.010299956639815, blendHz: 66.33249580710795, fadeHz: 1500, incomingHz: 66.33249580710803),
    Instant(progress: 0.52, outgoingGain: 0.9980267284282716, incomingGain: 1, outgoingCut: 0.75, incomingCut: 0.25, outgoingDb: -8.343206788338346, incomingDb: -0.6876930815810872, blendHz: 120.80210709074473, fadeHz: 1500, incomingHz: 36.42320573675744),
    Instant(progress: 0.54, outgoingGain: 0.9921147013144778, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: 0.6, outgoingGain: 0.9510565162951536, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: 0.75, outgoingGain: 0.7071067811865476, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: 0.9, outgoingGain: 0.30901699437494745, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: 1, outgoingGain: 0, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: 2, outgoingGain: 0, incomingGain: 1, outgoingCut: 1, incomingCut: 0, outgoingDb: -24, incomingDb: 0, blendHz: 220, fadeHz: 1500, incomingHz: 20),
    Instant(progress: .nan, outgoingGain: 1, incomingGain: 0, outgoingCut: 0, incomingCut: 1, outgoingDb: 0, incomingDb: -24, blendHz: 20, fadeHz: 20, incomingHz: 220),
]

/// `(outgoing BPM, incoming BPM, seconds after the mix ends, incoming rate)`
/// for the ease back to the record's own tempo. Read off the deck after a
/// rendered mix, so the ease is the one a listener gets rather than the one
/// the arithmetic describes; the desktop reads its `restoreRate` for the same
/// rows.
private struct Restore: Sendable, CustomTestStringConvertible {
    let outgoingBpm: Double
    let incomingBpm: Double
    let secondsAfter: Double
    let rate: Double
    var testDescription: String { "\(outgoingBpm) over \(incomingBpm): \(secondsAfter)s after the mix the bend is \(rate)" }
}

private let restores: [Restore] = [
    Restore(outgoingBpm: 128, incomingBpm: 124, secondsAfter: 0, rate: 1.032258064516129),
    Restore(outgoingBpm: 128, incomingBpm: 124, secondsAfter: 2, rate: 1.0241935483870968),
    Restore(outgoingBpm: 128, incomingBpm: 124, secondsAfter: 4, rate: 1.0161290322580645),
    Restore(outgoingBpm: 128, incomingBpm: 124, secondsAfter: 8, rate: 1),
    Restore(outgoingBpm: 128, incomingBpm: 132, secondsAfter: 0, rate: 0.9696969696969697),
    Restore(outgoingBpm: 128, incomingBpm: 132, secondsAfter: 4, rate: 0.9848484848484849),
    Restore(outgoingBpm: 128, incomingBpm: 132, secondsAfter: 8, rate: 1),
]

@Suite("DJ automation parity")
struct DJAutomationParityTests {
    private static let sampleRate = 44_100.0

    @Test("moves the desktop's faders and filters identically", arguments: table)
    fileprivate func instant(_ row: Instant) {
        #expect(abs(DJAutomation.outgoingGain(progress: row.progress) - row.outgoingGain) < 1e-9)
        #expect(abs(DJAutomation.incomingGain(progress: row.progress) - row.incomingGain) < 1e-9)
        #expect(abs(DJAutomation.outgoingBassCut(progress: row.progress) - row.outgoingCut) < 1e-9)
        #expect(abs(DJAutomation.incomingBassCut(progress: row.progress) - row.incomingCut) < 1e-9)
        #expect(abs(DJAutomation.outgoingBassDb(progress: row.progress) - row.outgoingDb) < 1e-9)
        #expect(abs(DJAutomation.incomingBassDb(progress: row.progress) - row.incomingDb) < 1e-9)

        // The corners as the mixer sets them, in the mixer's own single precision.
        let mixer = DJMixer()
        mixer.setHighPass(hz: DJAutomation.outgoingHighPassHz(progress: row.progress, style: .blend), on: .a)
        #expect(abs(mixer.bassCornerHz(on: .a) - row.blendHz) < 0.01, "blend corner \(mixer.bassCornerHz(on: .a))")
        mixer.setHighPass(hz: DJAutomation.outgoingHighPassHz(progress: row.progress, style: .filterFade), on: .a)
        #expect(abs(mixer.bassCornerHz(on: .a) - row.fadeHz) < 0.01, "fade corner \(mixer.bassCornerHz(on: .a))")
        mixer.setHighPass(hz: DJAutomation.incomingHighPassHz(progress: row.progress), on: .b)
        #expect(abs(mixer.bassCornerHz(on: .b) - row.incomingHz) < 0.01, "incoming corner \(mixer.bassCornerHz(on: .b))")
    }

    /// A record: a steady tone, long enough to mix out of and into.
    private func record(seconds: Double = 120) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<total {
            samples[frame] = Float(0.2 * sin(2 * .pi * 60 * Double(frame) / Self.sampleRate))
        }
        try file.write(from: buffer)
        return url
    }

    private func grid(bpm: Double, mixInMs: Double? = nil, mixOutMs: Double? = nil) -> BeatGrid {
        BeatGrid(
            segments: [BeatGrid.Segment(startMs: 0, endMs: 120_000, anchorMs: 0, bpm: bpm, residualMs: 4, beats: Int(120_000 / (60_000 / bpm)))],
            beatsPerBar: 4,
            downbeatIndex: 0,
            mixInMs: mixInMs ?? 0,
            mixOutMs: mixOutMs ?? 90_000
        )
    }

    private func read(energy: Double) -> Arrangement {
        Arrangement(sections: [Arrangement.Section(startMs: 0, endMs: 600_000, kind: .unknown, energy: energy)], vocals: [])
    }

    @Test("eases the bend back as the desktop does", arguments: restores)
    fileprivate func restore(_ row: Restore) throws {
        let outgoing = try record()
        let incoming = try record()
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.sampleRate, channels: 1)
        try mixer.start()

        // Eight bars from 80.625 s to 95.625 s of the outgoing record, which is
        // 1.125 s to 16.125 s of the session once it has been seeked to 79.5.
        let outgoingGrid = grid(bpm: row.outgoingBpm, mixOutMs: 95_625)
        let incomingGrid = grid(bpm: row.incomingBpm)
        let transition = try #require(DJPlanner.plan(
            outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000,
            outgoingArrangement: read(energy: 0.8), incomingArrangement: read(energy: 0.2)
        ))
        #expect(abs(transition.incomingRate - row.outgoingBpm / row.incomingBpm) < 1e-9)
        let mixEnd = (transition.outgoingStartMs / 1000 - 79.5) + transition.seconds

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        // The automation runs once per render block, so the rate read at the end
        // is the one set within a block of the moment asked for.
        _ = try mixer.renderOffline(seconds: mixEnd + row.secondsAfter + 0.2) { session.update(at: $0) }
        #expect(session.playingSide == .b)
        #expect(abs(mixer.rate(on: .b) - row.rate) < 0.001, "rate \(mixer.rate(on: .b))")
    }

    @Test("answers every case in the tables")
    func everyCase() {
        #expect(table.count == 16)
        #expect(restores.count == 7)
    }
}
