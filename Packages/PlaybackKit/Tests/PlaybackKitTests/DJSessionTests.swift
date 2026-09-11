import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// A record that has been read and found unremarkable: one section nobody
/// could name, instrumental, no phrase grid. The planner now refuses a record
/// that has not been read at all — matching tempo is not a substitute for
/// knowing the arrangement — so every pair here is handed one of these. The
/// two energies differ so that a pair with nothing else going for it lands on
/// sixteen bars rather than being flattered into thirty-two.
private func read(energy: Double) -> Arrangement {
    Arrangement(
        sections: [Arrangement.Section(startMs: 0, endMs: 600_000, kind: .unknown, energy: energy)],
        vocals: []
    )
}

private func planned(outgoing: BeatGrid, incoming: BeatGrid, notBeforeMs: Double = 0) -> DJTransition? {
    DJPlanner.plan(
        outgoing: outgoing, incoming: incoming, notBeforeMs: notBeforeMs,
        outgoingArrangement: read(energy: 0.8), incomingArrangement: read(energy: 0.2)
    )
}

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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))
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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))

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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))
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

        // And the position is where the record actually is: fifteen seconds of
        // mix at the bent rate, eight seconds easing back to 1, the rest at 1.
        // Multiplying the whole time by the rate it has *now* — which is what
        // this used to do — puts it more than half a second ahead, for good.
        let mixBeganAt = transition.outgoingStartMs / 1000 - 79.5
        let mixLength = Double(transition.bars) * 4 * 60 / transition.targetBpm
        let restore = transition.restoreSeconds
        let expected = transition.incomingStartMs / 1000
            + mixLength * transition.incomingRate
            + restore * (transition.incomingRate + 1) / 2
            + (28 - mixBeganAt - mixLength - restore)
        let position = session.position(at: 28)
        #expect(abs(position - expected) < 0.03, "position \(position), expected \(expected)")
        let naive = transition.incomingStartMs / 1000 + (28 - mixBeganAt)
        #expect(expected - naive > 0.5)
    }

    @Test("A pause is not time played, and a mix booked across it is booked again")
    func pauseKeepsTime() throws {
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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)
        #expect(session.hasScheduledMix)

        // Half a second in, paused. The engine's clock keeps running for two
        // seconds — through the moment the mix was booked to begin.
        _ = try mixer.renderOffline(seconds: 0.5) { session.update(at: $0) }
        session.pause(at: 0.5)
        #expect(!session.hasScheduledMix, "a booking the clock would have honoured over silence is abandoned")
        let silent = try mixer.renderOffline(seconds: 2) { session.update(at: 0.5 + $0) }
        // The player node takes a pause at its next render; offline that is
        // one block of 4096 frames, 93 ms. After that, nothing.
        #expect(clickTimes(in: silent, threshold: 0.01).allSatisfy { $0 < 0.1 }, "nothing sounds while paused")
        #expect(abs(session.position(at: 2.5) - 80.0) < 1e-6, "paused at 80.0, still 80.0")

        session.resume(at: 2.5)
        _ = try mixer.renderOffline(seconds: 1) { session.update(at: 2.5 + $0) }
        // Three and a half seconds on the clock; one and a half played.
        #expect(abs(session.position(at: 3.5) - 81.0) < 1e-6, "position \(session.position(at: 3.5))")
        #expect(session.phase == .playing)
        #expect(session.playingSide == .a)
    }

    @Test("A pause in the middle of a mix moves the mix, not the crossfader")
    func pauseMidMix() throws {
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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        // Five seconds in, well into the mix. Paused for three.
        _ = try mixer.renderOffline(seconds: 5) { session.update(at: $0) }
        #expect(session.phase == .mixing)
        let before = try #require(session.mixProgress(at: 5))
        let heardBefore = session.heardPosition(at: 5)
        session.pause(at: 5)
        _ = try mixer.renderOffline(seconds: 3) { session.update(at: 5 + $0) }
        session.resume(at: 8)
        // The crossfader is where it was, and so is the incoming record.
        let after = try #require(session.mixProgress(at: 8))
        #expect(abs(after - before) < 0.01, "progress \(before) → \(after)")
        #expect(abs(session.heardPosition(at: 8) - heardBefore) < 0.02)
        #expect(session.phase == .mixing)
        // And the mix runs to its end from there, not three seconds early.
        _ = try mixer.renderOffline(seconds: 8) { session.update(at: 8 + $0) }
        #expect(session.phase == .mixing, "still mixing: the mix ends 15 s after it began plus the 3 s pause")
        _ = try mixer.renderOffline(seconds: 5) { session.update(at: 16 + $0) }
        #expect(session.phase == .playing)
        #expect(session.playingSide == .b)
    }

    @Test("What is heard follows the incoming record from the moment the mix begins")
    func heardPositionFollowsTheIncomingRecord() throws {
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
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 80_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: 79.5, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        // Before the mix, heard and playing are the same record.
        _ = try mixer.renderOffline(seconds: 0.5) { session.update(at: $0) }
        #expect(session.phase == .playing)
        #expect(abs(session.heardPosition(at: 0.5) - session.position(at: 0.5)) < 1e-9)

        // Ten seconds in — the mix began when the outgoing record, started at
        // 79.5 s, reached its mix-out point — the outgoing record is past
        // ninety seconds, and what is heard is the incoming record, as far
        // into itself as the mix is old, at its bent rate.
        _ = try mixer.renderOffline(seconds: 9.5) { session.update(at: 0.5 + $0) }
        #expect(session.phase == .mixing)
        let heard = session.heardPosition(at: 10)
        #expect(session.position(at: 10) > 88)
        let mixBeganAt = transition.outgoingStartMs / 1000 - 79.5
        let expected = transition.incomingStartMs / 1000 + (10 - mixBeganAt) * transition.incomingRate
        #expect(abs(heard - expected) < 0.05, "heard \(heard), expected \(expected)")

        // When the mix ends the incoming record is the record playing, and the
        // figure does not jump: it is the same clock, read the same way.
        let mixEndsAt = mixBeganAt + transition.seconds
        _ = try mixer.renderOffline(seconds: mixEndsAt - 0.01 - 10) { session.update(at: 10 + $0) }
        #expect(session.phase == .mixing)
        let before = session.heardPosition(at: mixEndsAt - 0.01)
        // Two hundred milliseconds on — the automation runs once a block
        // offline, so the end is noticed within a block of it — and the record
        // has moved by that at its bent rate, give or take the first few
        // milliseconds of easing back. Nothing jumps.
        _ = try mixer.renderOffline(seconds: 0.2) { session.update(at: mixEndsAt - 0.01 + $0) }
        #expect(session.phase == .playing)
        #expect(session.playingSide == .b)
        let after = session.heardPosition(at: mixEndsAt + 0.19)
        #expect(abs(after - before - 0.2 * transition.incomingRate) < 0.005, "jumped from \(before) to \(after)")
    }
}

@Suite("A cut, end to end")
struct DJCutTests {
    private static let rate = 44_100.0

    /// A record of clicks at `bpm`, so what rings after a cut can be counted.
    private func clicks(bpm: Double, seconds: Double = 120) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cut-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<total { samples[frame] = 0 }
        let beatMs = 60_000 / bpm
        let clickFrames = Int(0.002 * Self.rate)
        var index = 0
        while true {
            let start = Int(Double(index) * beatMs / 1000 * Self.rate)
            guard start + clickFrames < total else { break }
            for frame in 0..<clickFrames {
                samples[start + frame] = Float(0.8 * (1 - Double(frame) / Double(clickFrames)) * sin(2 * .pi * 1_500 * Double(frame) / Self.rate))
            }
            index += 1
        }
        try file.write(from: buffer)
        return url
    }

    private func grid(bpm: Double, mixOutMs: Double) -> BeatGrid {
        BeatGrid(
            segments: [BeatGrid.Segment(startMs: 0, endMs: 120_000, anchorMs: 0, bpm: bpm, residualMs: 4, beats: Int(120_000 / (60_000 / bpm)))],
            beatsPerBar: 4, downbeatIndex: 0, mixInMs: 0, mixOutMs: mixOutMs
        )
    }

    /// The loudest sample within 30 ms after each time given.
    private func clickPeaks(in buffer: AVAudioPCMBuffer, at times: [Double]) -> [Float] {
        let samples = buffer.floatChannelData![0]
        let rate = buffer.format.sampleRate
        return times.map { time in
            let start = Int(time * rate)
            let end = min(Int(buffer.frameLength), start + Int(0.03 * rate))
            return (start..<end).map { abs(samples[$0]) }.max() ?? 0
        }
    }

    /// Clicks, with a hold long enough that an echo's darkened, lengthened
    /// repeat still counts as one click and not two.
    private func clickTimes(in buffer: AVAudioPCMBuffer, threshold: Float = 0.1, holdSeconds: Double = 0.03) -> [Double] {
        let samples = buffer.floatChannelData![0]
        var times: [Double] = []
        var frame = 0
        while frame < Int(buffer.frameLength) {
            if abs(samples[frame]) > threshold {
                times.append(Double(frame) / buffer.format.sampleRate)
                frame += Int(holdSeconds * buffer.format.sampleRate)
            } else {
                frame += 1
            }
        }
        return times
    }

    @Test("The outgoing record stops on the line and the new one starts that instant")
    func cutFalls() throws {
        // 128 out, 100 in: unbendable, so a cut. Both instrumental and level, so
        // a plain one rather than an echo.
        let outgoing = try clicks(bpm: 128)
        let incoming = try clicks(bpm: 100)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }
        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let bar = 60_000 / 128.0 * 4
        let read = Arrangement(sections: [.init(startMs: 0, endMs: 120_000, kind: .unknown, energy: 0.5)], phraseBars: 4, phraseAnchorMs: 0, vocals: [])
        let outGrid = grid(bpm: 128, mixOutMs: bar * 40)
        let inGrid = grid(bpm: 100, mixOutMs: 100_000)
        let cut = try #require(DJPlanner.planCut(outgoing: outGrid, incoming: inGrid, outgoingArrangement: read, incomingArrangement: read))
        #expect(cut.style == .cut)

        try session.start(DJItem(url: outgoing, grid: outGrid), at: 0)
        try session.seek(to: cut.outgoingStartMs / 1_000 - 2, at: 0)
        try session.schedule(cut, into: DJItem(url: incoming, grid: inGrid), at: 0)
        let rendered = try mixer.renderOffline(seconds: 6) { session.update(at: $0) }

        let times = clickTimes(in: rendered)
        // Before the cut, clicks at 128; after it, at 100 — and nothing at 128
        // any more, which is what "stops" means.
        let before = times.filter { $0 < 2 }
        let after = times.filter { $0 > 2.1 }
        let gapsBefore = zip(before, before.dropFirst()).map { $1 - $0 }
        let gapsAfter = zip(after, after.dropFirst()).map { $1 - $0 }
        #expect(gapsBefore.allSatisfy { abs($0 - 60.0 / 128) < 0.005 })
        #expect(gapsAfter.allSatisfy { abs($0 - 60.0 / 100) < 0.005 }, "gaps after the cut: \(gapsAfter.map { Int($0 * 1000) })")
        #expect(session.playingSide == .b)
        #expect(!mixer.isRunning(.a))
    }

    @Test("An echo-out leaves the last beat ringing, and then it stops")
    func echoRings() throws {
        let outgoing = try clicks(bpm: 128)
        let incoming = try clicks(bpm: 100)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }
        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let bar = 60_000 / 128.0 * 4
        // Loud out, quiet in: an echo-out.
        let loud = Arrangement(sections: [.init(startMs: 0, endMs: 120_000, kind: .drop, energy: 1.0)], phraseBars: 4, phraseAnchorMs: 0, vocals: [])
        let quiet = Arrangement(sections: [.init(startMs: 0, endMs: 120_000, kind: .intro, energy: 0.2)], phraseBars: 4, phraseAnchorMs: 0, vocals: [])
        let outGrid = grid(bpm: 128, mixOutMs: bar * 40)
        let inGrid = grid(bpm: 100, mixOutMs: 100_000)
        let echo = try #require(DJPlanner.planCut(outgoing: outGrid, incoming: inGrid, outgoingArrangement: loud, incomingArrangement: quiet))
        #expect(echo.style == .echoOut)

        // The incoming record silent, so only the ring is measured.
        try session.start(DJItem(url: outgoing, grid: outGrid), at: 0)
        try session.seek(to: echo.outgoingStartMs / 1_000 - 2, at: 0)
        try session.schedule(echo, into: DJItem(url: incoming, gainDb: -60, grid: inGrid), at: 0)
        let tail = DJPlanner.echoTailSeconds(targetBpm: 128)
        #expect(abs(tail - 3.75) < 1e-9, "two bars at 128")
        let rendered = try mixer.renderOffline(seconds: 8) { session.update(at: $0) }

        let times = clickTimes(in: rendered, threshold: 0.05, holdSeconds: 0.15)
        // Repeats after the cut, one beat of the *outgoing* tempo apart,
        // several of them — a tail, not a hiccup — and gone within it.
        let ring = times.filter { $0 > 2.05 && $0 < 2 + tail + 0.5 }
        #expect(ring.count >= 5, "heard \(ring.count) repeats")
        let gaps = zip(ring, ring.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { abs($0 - 60.0 / 128) < 0.015 }, "gaps \(gaps.map { Int($0 * 1000) })")
        // The fader does not touch the first repeats: the third is still
        // within a few decibels of what the feedback alone would give.
        let peaks = clickPeaks(in: rendered, at: ring)
        if peaks.count >= 3 {
            let expected = pow(0.6, 2) * peaks[0]
            #expect(peaks[2] > expected * 0.7, "third repeat \(peaks[2]) against \(expected) from feedback alone")
        }
        // Silence once the tail is over.
        let late = times.filter { $0 > 2 + tail + 0.6 }
        #expect(late.isEmpty, "still ringing at \(late.first ?? 0)s")
    }
}
