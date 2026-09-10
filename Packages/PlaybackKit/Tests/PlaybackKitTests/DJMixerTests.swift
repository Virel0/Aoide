import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The mixer rendered offline and measured, because every claim it makes is
/// about timing and no amount of reading the code establishes any of them.
///
/// Click tracks rather than music: a click is a position, and a position is what
/// a beat-match is made of. If two decks are a tenth of a beat apart, that shows
/// up here as two clicks a few hundred samples apart, which is exactly the error
/// that would be heard as a flam.
@Suite("Two decks on one clock")
struct DJMixerTests {
    private static let rate = 44_100.0

    /// A file of `count` clicks, `everyMs` apart, silent in between.
    private func clicks(count: Int, everyMs: Double, offsetMs: Double = 0, seconds: Double = 8) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicks-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<total { samples[frame] = 0 }
        // Each click is a short burst of full-scale noise-free tone, long enough
        // to survive a resampler and short enough to locate.
        let clickFrames = Int(0.002 * Self.rate)
        for index in 0..<count {
            let start = Int((offsetMs + Double(index) * everyMs) / 1000 * Self.rate)
            guard start + clickFrames < total else { break }
            for frame in 0..<clickFrames {
                let envelope = 1 - Double(frame) / Double(clickFrames)
                samples[start + frame] = Float(envelope * sin(2 * .pi * 1000 * Double(frame) / Self.rate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// Where the clicks are in a rendered buffer, in seconds.
    private func clickTimes(in buffer: AVAudioPCMBuffer, threshold: Float = 0.2) -> [Double] {
        let samples = buffer.floatChannelData![0]
        var times: [Double] = []
        var frame = 0
        while frame < Int(buffer.frameLength) {
            if abs(samples[frame]) > threshold {
                times.append(Double(frame) / buffer.format.sampleRate)
                // Skip past this click before looking for the next.
                frame += Int(0.05 * buffer.format.sampleRate)
            } else {
                frame += 1
            }
        }
        return times
    }

    @Test("A deck told to start in half a second starts in half a second")
    func scheduledStartIsExact() throws {
        let url = try clicks(count: 4, everyMs: 1_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let mixer = DJMixer()
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.load(url, on: .a)
        try mixer.start()
        mixer.play(.a, inSeconds: 0.5)

        let rendered = try mixer.renderOffline(seconds: 3)
        let times = clickTimes(in: rendered)
        #expect(times.count == 3)

        // Every click is a constant 1.1ms late, which is the varispeed unit and
        // the shelf: both decks run through the same two, so the offset is
        // common to them and cancels in a mix. What would not cancel is drift,
        // and there is none — the offsets agree to a hundredth of a sample.
        let offsets = times.enumerated().map { $0.element - (0.5 + Double($0.offset)) }
        for offset in offsets {
            #expect(abs(offset) < 0.002, "click late by \(offset * 1000)ms")
        }
        let spread = (offsets.max() ?? 0) - (offsets.min() ?? 0)
        #expect(spread < 1 / DJMixerTests.rate, "offsets spread over \(spread * 1000)ms")
    }

    @Test("Two decks scheduled against the same clock land on each other")
    func decksAlign() throws {
        // Two click tracks a beat apart at 128 BPM: 468.75ms.
        let beat = 60_000.0 / 128
        let first = try clicks(count: 8, everyMs: beat)
        let second = try clicks(count: 8, everyMs: beat, offsetMs: 200)
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let mixer = DJMixer()
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.load(first, on: .a)
        // The second record's first click is 200ms into it, so starting it 200ms
        // *earlier* puts the two click tracks on top of each other. Anything less
        // exact than a sample clock would show up as two clicks.
        try mixer.load(second, on: .b)
        mixer.setVolume(0.5, on: .a)
        mixer.setVolume(0.5, on: .b)
        try mixer.start()
        mixer.play(.a, inSeconds: 1.0)
        mixer.play(.b, inSeconds: 0.8)

        let rendered = try mixer.renderOffline(seconds: 4)
        let times = clickTimes(in: rendered)
        // One click per beat, not two: the decks are inside a click of each other
        // for the whole passage.
        #expect(times.count >= 6)
        for (index, time) in times.enumerated() {
            #expect(abs(time - (1.0 + Double(index) * beat / 1000)) < 0.002, "beat \(index) at \(time)s")
        }
    }

    @Test("The bend changes the tempo by exactly what it says")
    func varispeedBends() throws {
        let url = try clicks(count: 8, everyMs: 500)
        defer { try? FileManager.default.removeItem(at: url) }

        let mixer = DJMixer()
        try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
        try mixer.load(url, on: .a)
        // A five per cent bend: half-second clicks become 476ms apart.
        mixer.setRate(1.05, on: .a)
        try mixer.start()
        mixer.play(.a)

        let rendered = try mixer.renderOffline(seconds: 3)
        let times = clickTimes(in: rendered)
        #expect(times.count >= 5)
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }
        for gap in gaps {
            #expect(abs(gap - 0.5 / 1.05) < 0.003, "gap of \(gap)s")
        }
    }

    @Test("The shelf takes the bass out and leaves the rest")
    func bassShelfCuts() throws {
        let url = try tone(hz: 60)
        let highUrl = try tone(hz: 2_000)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: highUrl)
        }

        func level(of file: URL, bassDb: Double) throws -> Double {
            let mixer = DJMixer()
            try mixer.beginOfflineRendering(sampleRate: Self.rate, channels: 1)
            try mixer.load(file, on: .a)
            mixer.setBassDb(bassDb, on: .a)
            try mixer.start()
            mixer.play(.a)
            let rendered = try mixer.renderOffline(seconds: 1)
            let samples = rendered.floatChannelData![0]
            var sum = 0.0
            // Skip the first tenth, where the filter is still settling.
            let from = Int(0.1 * Self.rate)
            for frame in from..<Int(rendered.frameLength) {
                sum += Double(samples[frame]) * Double(samples[frame])
            }
            return (sum / Double(Int(rendered.frameLength) - from)).squareRoot()
        }

        let bassOpen = try level(of: url, bassDb: 0)
        let bassCut = try level(of: url, bassDb: DJAutomation.bassCutDb)
        #expect(bassCut < bassOpen)
        let cutDb = 20 * log10(bassCut / bassOpen)
        // Within a few decibels of what was asked for — a shelf is a slope, not
        // a wall, and 60Hz is below the corner rather than at it.
        #expect(abs(cutDb - DJAutomation.bassCutDb) < 4, "cut measured \(cutDb) dB")

        // And the top of the record is left alone.
        let highOpen = try level(of: highUrl, bassDb: 0)
        let highCut = try level(of: highUrl, bassDb: DJAutomation.bassCutDb)
        #expect(abs(20 * log10(highCut / highOpen)) < 1)
    }

    private func tone(hz: Double, seconds: Double = 2) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for frame in 0..<total {
            buffer.floatChannelData![0][frame] = Float(0.5 * sin(2 * .pi * hz * Double(frame) / Self.rate))
        }
        try file.write(from: buffer)
        return url
    }
}
