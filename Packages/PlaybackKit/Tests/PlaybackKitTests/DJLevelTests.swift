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

/// What a mix does to the level, measured rather than reasoned about.
///
/// The complaint that produced this suite: "the volume lowered a lot and I had
/// to turn it back up". Two records crossing should sound like one record
/// playing — that is the entire promise — so the envelope through a mix is a
/// thing to assert on, not to hope for.
@Suite("The level through a mix")
struct DJLevelTests {
    private static let rate = 44_100.0

    /// A record with a kick-ish low end and a body above it, which is what makes
    /// a level measurement mean anything.
    private func record(bpm: Double, bassHz: Double, bodyHz: Double, seconds: Double = 120) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lvl-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<total {
            let t = Double(frame) / Self.rate
            samples[frame] = Float(0.35 * sin(2 * .pi * bassHz * t) + 0.25 * sin(2 * .pi * bodyHz * t))
        }
        try file.write(from: buffer)
        return url
    }

    private func grid(bpm: Double, mixInMs: Double = 0, mixOutMs: Double) -> BeatGrid {
        BeatGrid(
            segments: [BeatGrid.Segment(startMs: 0, endMs: 120_000, anchorMs: 0, bpm: bpm, residualMs: 4, beats: 300)],
            beatsPerBar: 4,
            downbeatIndex: 0,
            mixInMs: mixInMs,
            mixOutMs: mixOutMs
        )
    }

    /// RMS in decibels, in windows across the whole buffer.
    private func envelope(_ buffer: AVAudioPCMBuffer, window: Double = 0.25) -> [(seconds: Double, db: Double)] {
        let samples = buffer.floatChannelData![0]
        let per = Int(window * buffer.format.sampleRate)
        var out: [(Double, Double)] = []
        var start = 0
        while start + per <= Int(buffer.frameLength) {
            var sum = 0.0
            for frame in start..<(start + per) { sum += Double(samples[frame]) * Double(samples[frame]) }
            let rms = (sum / Double(per)).squareRoot()
            out.append((Double(start) / buffer.format.sampleRate, 20 * log10(max(rms, 1e-9))))
            start += per
        }
        return out.map { (seconds: $0.0, db: $0.1) }
    }

    /// The largest jump between two neighbouring samples, and where it is.
    ///
    /// A click is exactly that: a discontinuity. Two tones under 600 Hz cannot
    /// move faster than about 0.05 between samples on their own, so anything
    /// much above that came from a gain or a filter being stepped rather than
    /// ramped — which is what a listener hears as the mix crackling.
    private func largestJump(_ buffer: AVAudioPCMBuffer, after: Double = 0) -> (seconds: Double, jump: Double) {
        let samples = buffer.floatChannelData![0]
        var worst = (seconds: 0.0, jump: 0.0)
        // The first instant is the record being started mid-waveform, which in
        // the app has already happened long before any mix.
        for frame in max(1, Int(after * buffer.format.sampleRate))..<Int(buffer.frameLength) {
            let jump = abs(Double(samples[frame]) - Double(samples[frame - 1]))
            if jump > worst.jump {
                worst = (Double(frame) / buffer.format.sampleRate, jump)
            }
        }
        return worst
    }

    @Test("Nothing in a mix is stepped hard enough to click")
    func noClicks() throws {
        let outgoing = try record(bpm: 164, bassHz: 55, bodyHz: 440)
        let incoming = try record(bpm: 170, bassHz: 62, bodyHz: 587)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let bar = 60_000 / 164.0 * 4
        let outgoingGrid = grid(bpm: 164, mixOutMs: (100_000 / bar).rounded(.down) * bar)
        let incomingGrid = grid(bpm: 170, mixOutMs: 100_000)
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 60_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: transition.outgoingStartMs / 1_000 - 1, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        let rendered = try mixer.renderOffline(seconds: transition.seconds + 3) { elapsed in
            session.update(at: elapsed)
        }

        let worst = largestJump(rendered, after: 0.5)
        // The two records together cannot exceed about 0.1 between samples by
        // playing; anything past that is a parameter change with an edge on it.
        #expect(worst.jump < 0.12, "a jump of \(worst.jump) at \(worst.seconds)s")
    }

    @Test("The filter fade thins the outgoing record without the pair collapsing")
    func filterFadeHolds() throws {
        // Keys known to clash, so the pair gets the filter fade: the outgoing
        // record's body goes before the swap and only its top is left.
        let outgoing = try record(bpm: 128, bassHz: 55, bodyHz: 440)
        let incoming = try record(bpm: 128, bassHz: 62, bodyHz: 587)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let bar = 60_000 / 128.0 * 4
        var outgoingGrid = grid(bpm: 128, mixOutMs: (100_000 / bar).rounded(.down) * bar)
        var incomingGrid = grid(bpm: 128, mixOutMs: 100_000)
        outgoingGrid = BeatGrid(segments: outgoingGrid.segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: outgoingGrid.mixInMs, mixOutMs: outgoingGrid.mixOutMs, key: "3B")
        incomingGrid = BeatGrid(segments: incomingGrid.segments, beatsPerBar: 4, downbeatIndex: 0, mixInMs: incomingGrid.mixInMs, mixOutMs: incomingGrid.mixOutMs, key: "10B")
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 60_000))
        #expect(transition.style == .filterFade)

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: transition.outgoingStartMs / 1_000 - 1, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        let rendered = try mixer.renderOffline(seconds: transition.seconds + 3) { elapsed in
            session.update(at: elapsed)
        }

        let envelope = envelope(rendered)
        let reference = envelope.first { $0.seconds > 0.3 }?.db ?? 0
        let during = envelope.filter { $0.seconds > 1.5 && $0.seconds < transition.seconds }
        let quietest = during.min { $0.db < $1.db }
        // Thinner than a blend by design, but never a hole: the incoming record
        // is coming up as the outgoing one thins.
        #expect((quietest?.db ?? 0) > reference - 6, "dropped to \((quietest?.db ?? 0) - reference) dB at \(quietest?.seconds ?? 0)s")
    }

    @Test("A mix never drops below one record playing on its own")
    func levelHolds() throws {
        // 164 into 170: a real pair, from a real complaint.
        let outgoing = try record(bpm: 164, bassHz: 55, bodyHz: 440)
        let incoming = try record(bpm: 170, bassHz: 62, bodyHz: 587)
        defer {
            try? FileManager.default.removeItem(at: outgoing)
            try? FileManager.default.removeItem(at: incoming)
        }

        let mixer = DJMixer()
        let session = DJSession(mixer: mixer)
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.start()

        let bar = 60_000 / 164.0 * 4
        let outgoingGrid = grid(bpm: 164, mixOutMs: (100_000 / bar).rounded(.down) * bar)
        let incomingGrid = grid(bpm: 170, mixOutMs: 100_000)
        let transition = try #require(planned(outgoing: outgoingGrid, incoming: incomingGrid, notBeforeMs: 60_000))

        try session.start(DJItem(url: outgoing, grid: outgoingGrid), at: 0)
        try session.seek(to: transition.outgoingStartMs / 1_000 - 1, at: 0)
        try session.schedule(transition, into: DJItem(url: incoming, grid: incomingGrid), at: 0)

        var sawMixing = false
        let rendered = try mixer.renderOffline(seconds: transition.seconds + 4) { elapsed in
            session.update(at: elapsed)
            if session.phase == .mixing { sawMixing = true }
        }
        #expect(sawMixing)

        let envelope = envelope(rendered)
        // One record alone, before anything crosses.
        let reference = envelope.first { $0.seconds > 0.3 }?.db ?? 0
        let during = envelope.filter { $0.seconds > 1.5 && $0.seconds < transition.seconds }

        let quietest = during.min { $0.db < $1.db }
        let loudest = during.max { $0.db < $1.db }
        // Two decibels, not three: the complaint was a mix that needed the
        // volume turning up, and a mix within two decibels of one record playing
        // is a mix nobody reaches for the dial during.
        #expect((quietest?.db ?? 0) > reference - 2,
                "dropped to \((quietest?.db ?? 0) - reference) dB at \(quietest?.seconds ?? 0)s")
        #expect((loudest?.db ?? 0) < reference + 2,
                "rose to \((loudest?.db ?? 0) - reference) dB at \(loudest?.seconds ?? 0)s")
    }
}
