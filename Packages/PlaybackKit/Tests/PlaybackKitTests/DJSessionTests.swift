import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// A whole mix, rendered offline and measured.
///
/// The suite that says whether Auto DJ works. Everything else about it is
/// arithmetic that can be reasoned about; this is the part where two records
/// actually run together and either stay in time or do not.
@Suite("A mix, end to end")
struct DJSessionTests {
    private static let rate = 44_100.0

    /// A record: clicks on every beat at `bpm`, plus a steady tone underneath at
    /// `bassHz` so the bass swap has something to act on.
    ///
    /// Two records in a mix are given *different* bass notes on purpose. With the
    /// same note, the swap is invisible to any measurement: the volume curve is
    /// equal-power, so the total low end is the same whether one record has been
    /// cut or both are playing. Only a note that belongs to one record can say
    /// which record the low end is coming from.
    private func record(bpm: Double, seconds: Double = 120, offsetMs: Double = 0, bassHz: Double = 60) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("record-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<total {
            samples[frame] = Float(0.2 * sin(2 * .pi * bassHz * Double(frame) / Self.rate))
        }
        let beatMs = 60_000 / bpm
        let clickFrames = Int(0.002 * Self.rate)
        var index = 0
        while true {
            let start = Int((offsetMs + Double(index) * beatMs) / 1000 * Self.rate)
            guard start + clickFrames < total else { break }
            for frame in 0..<clickFrames {
                let envelope = 1 - Double(frame) / Double(clickFrames)
                samples[start + frame] += Float(0.8 * envelope * sin(2 * .pi * 1_500 * Double(frame) / Self.rate))
            }
            index += 1
        }
        try file.write(from: buffer)
        return url
    }

    /// A grid describing such a record exactly.
    private func grid(bpm: Double, anchorMs: Double = 0, lengthMs: Double = 120_000, mixInMs: Double? = nil, mixOutMs: Double? = nil) -> BeatGrid {
        BeatGrid(
            segments: [
                BeatGrid.Segment(
                    startMs: 0, endMs: lengthMs, anchorMs: anchorMs, bpm: bpm,
                    residualMs: 4, beats: Int(lengthMs / (60_000 / bpm))
                )
            ],
            beatsPerBar: 4,
            downbeatIndex: 0,
            mixInMs: mixInMs ?? anchorMs,
            mixOutMs: mixOutMs ?? 90_000
        )
    }

    /// Peaks above `threshold`, in seconds, with a hold so one click is one time.
    private func clickTimes(in buffer: AVAudioPCMBuffer, threshold: Float = 0.35) -> [Double] {
        let samples = buffer.floatChannelData![0]
        var times: [Double] = []
        var frame = 0
        while frame < Int(buffer.frameLength) {
            if abs(samples[frame]) > threshold {
                times.append(Double(frame) / buffer.format.sampleRate)
                frame += Int(0.08 * buffer.format.sampleRate)
            } else {
                frame += 1
            }
        }
        return times
    }

    /// How much of one note there is in a stretch of the buffer, as an amplitude.
    private func bassLevel(in buffer: AVAudioPCMBuffer, hz: Double = 60, from: Double, to: Double) -> Double {
        let samples = buffer.floatChannelData![0]
        let rate = buffer.format.sampleRate
        let start = Int(from * rate), end = min(Int(to * rate), Int(buffer.frameLength))
        guard end > start else { return 0 }
        // A single-bin Goertzel at 60Hz: the clicks are at 1.5kHz and do not
        // trouble it, which is why the record is built this way.
        var real = 0.0, imaginary = 0.0
        for frame in start..<end {
            let angle = 2 * .pi * hz * Double(frame) / rate
            real += Double(samples[frame]) * cos(angle)
            imaginary += Double(samples[frame]) * sin(angle)
        }
        let count = Double(end - start)
        return 2 * (real * real + imaginary * imaginary).squareRoot() / count
    }

    @Test("Two records mixed stay in time for the whole mix")
    func staysInTime() throws {
        // Both at 128, the incoming one a beat offset so only a scheduled start
        // could line them up.
        let outgoing = try record(bpm: 128)
        let incoming = try record(bpm: 128, offsetMs: 234)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        // Mix out at 95s and eight bars at 128 is fifteen seconds, so the mix
        // runs from 80s to 95s of the outgoing record. Start the record at 79s,
        // a second before that, or there would be no mix to book.
        let outgoingGrid = grid(bpm: 128, mixOutMs: 95_625)
        let incomingGrid = grid(bpm: 128, anchorMs: 234, mixInMs: 234 + 1_875 * 4)
        let transition = try #require(DJPlanner.plan(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))
        #expect(transition.bars == 8)

        try session.start(
            DJItem(url: outgoing, grid: outgoingGrid),
            at: 0
        )
        // Pretend the record is already 80 seconds in by seeking there.
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)
        #expect(session.hasScheduledMix)

        // Render the whole mix and a little either side.
        var sawMixing = false
        let rendered = try mixer.renderOffline(seconds: 18) { elapsed in
            session.update(at: elapsed)
            if session.phase == .mixing { sawMixing = true }
        }
        // Without this, a mix that never happened would sail through every
        // measurement below: one record playing on its own is perfectly in time
        // with itself.
        #expect(sawMixing)
        #expect(session.playingSide == .b)
        // The record that faded out is stopped, not merely turned down: a deck
        // at volume zero is still decoding and still there to be resumed.
        #expect(!mixer.isRunning(.a))
        #expect(mixer.isRunning(.b))

        let beat = 60.0 / 128
        let times = clickTimes(in: rendered)
        #expect(times.count > 30)

        // Where each click sits within its beat. The render begins wherever the
        // seek left the record, so the absolute phase is arbitrary — what is not
        // arbitrary is that it never changes: the same phase before the mix,
        // through it, and after it, when the clicks being heard belong to the
        // *other* record entirely.
        let phases = times.map { time -> Double in
            let position = time.truncatingRemainder(dividingBy: beat)
            return position > beat / 2 ? position - beat : position
        }
        let spread = (phases.max() ?? 0) - (phases.min() ?? 0)
        #expect(spread < 0.002, "clicks wander over \(spread * 1000)ms across the mix")

        // And the spacing is a beat throughout — no click is dropped or doubled.
        for (a, b) in zip(times, times.dropFirst()) {
            #expect(abs((b - a) - beat) < 0.003, "a gap of \((b - a) * 1000)ms")
        }

        // And there is no doubling: two records a beat apart would give two
        // clicks per beat through the middle of the mix.
        let inTheMiddle = times.filter { $0 > 6 && $0 < 9 }
        #expect(inTheMiddle.count <= Int(3 / beat) + 1, "\(inTheMiddle.count) clicks where there should be \(Int(3 / beat))")
    }

    @Test("The bass belongs to one record at a time")
    func bassSwaps() throws {
        // Different notes underneath so each record's low end can be followed
        // through the mix on its own.
        let outgoing = try record(bpm: 128, bassHz: 60)
        let incoming = try record(bpm: 128, offsetMs: 234, bassHz: 45)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let outgoingGrid = grid(bpm: 128, mixOutMs: 95_625)
        let incomingGrid = grid(bpm: 128, anchorMs: 234, mixInMs: 234 + 1_875 * 4)
        let transition = try #require(DJPlanner.plan(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        var sawMixing = false
        let rendered = try mixer.renderOffline(seconds: 17) { elapsed in
            session.update(at: elapsed)
            if session.phase == .mixing { sawMixing = true }
        }
        #expect(sawMixing)

        // The mix runs from about a second in to about sixteen, swapping a beat
        // either side of the middle. Early and late are the two halves.
        let early = (out: bassLevel(in: rendered, hz: 60, from: 5, to: 7),
                     into: bassLevel(in: rendered, hz: 45, from: 5, to: 7))
        let late = (out: bassLevel(in: rendered, hz: 60, from: 11, to: 13),
                    into: bassLevel(in: rendered, hz: 45, from: 11, to: 13))

        // Early: the outgoing record has the low end and the incoming one does
        // not, however loud the rest of it is by then.
        #expect(early.out > early.into * 5, "outgoing \(early.out) against incoming \(early.into)")
        // Late: it has changed hands.
        #expect(late.into > late.out * 5, "incoming \(late.into) against outgoing \(late.out)")
        // Each record's own low end is many times louder when it holds it than
        // when it does not — the swap, not a fade.
        #expect(late.into > early.into * 8, "incoming bass \(early.into) → \(late.into)")
        #expect(early.out > late.out * 8, "outgoing bass \(early.out) → \(late.out)")
    }

    @Test("A bent record gets its own tempo back afterwards")
    func restoresTempo() throws {
        let outgoing = try record(bpm: 128)
        let incoming = try record(bpm: 124)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let outgoingGrid = grid(bpm: 128, mixOutMs: 95_625)
        let incomingGrid = grid(bpm: 124, mixInMs: 0)
        let transition = try #require(DJPlanner.plan(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))
        #expect(abs(transition.incomingRate - 128.0 / 124.0) < 1e-9)

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        // Ten seconds in — the mix began at one second and runs fifteen — the
        // incoming deck is bent to meet the record it is coming in under.
        _ = try mixer.renderOffline(seconds: 10) { session.update(at: $0) }
        #expect(abs(mixer.rate(on: .b) - transition.incomingRate) < 0.001)

        _ = try mixer.renderOffline(seconds: 18) { session.update(at: 10 + $0) }
        // Eight seconds after the mix ends, the record has its own speed back.
        #expect(session.playingSide == .b)
        #expect(abs(mixer.rate(on: .b) - 1) < 0.001)
    }
}
