import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

@Suite("Silence bounds")
struct SilenceBoundsTests {
    private static let rate = 44_100.0

    /// A file of `leading` seconds of silence, `sound` seconds of tone, `trailing` seconds of silence.
    private func file(leading: Double, sound: Double, trailing: Double, amplitude: Float = 0.5) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silence-\(UUID()).m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 2, interleaved: false)!
        let writer = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16],
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let total = Int((leading + sound + trailing) * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        let from = Int(leading * Self.rate), to = Int((leading + sound) * Self.rate)
        for i in 0..<total {
            let v: Float = (i >= from && i < to) ? amplitude * Float(sin(2 * .pi * 440 * Double(i) / Self.rate)) : 0
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        try writer.write(from: buffer)
        writer.close()
        return url
    }

    private func close(_ a: Duration, _ b: Duration, within ms: Int64 = 60) -> Bool {
        abs((a - b).seconds * 1000) <= Double(ms)
    }

    @Test("finds the sound between leading and trailing silence, with margins")
    func bounds() throws {
        let url = try file(leading: 2, sound: 3, trailing: 2.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let found = try #require(try SilenceBounds.analyze(url))
        #expect(close(found.soundStart, .seconds(2) - SilenceBounds.leadMargin))
        #expect(close(found.soundEnd, .seconds(5) + SilenceBounds.tailMargin))
    }

    @Test("a file that starts and ends with sound is left alone")
    func nothingToTrim() throws {
        let url = try file(leading: 0, sound: 3, trailing: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SilenceBounds.analyze(url) == nil)
    }

    @Test("a trim too small to matter is left alone")
    func tooSmall() throws {
        let url = try file(leading: 0.1, sound: 3, trailing: 0.1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SilenceBounds.analyze(url) == nil)
    }

    @Test("silence at one end only is trimmed at that end")
    func oneEnd() throws {
        let url = try file(leading: 0, sound: 2, trailing: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let found = try #require(try SilenceBounds.analyze(url))
        #expect(found.soundStart == .zero)
        #expect(close(found.soundEnd, .seconds(2) + SilenceBounds.tailMargin))
    }

    @Test("a file with no sound at all is nothing to trim")
    func allSilent() throws {
        let url = try file(leading: 2, sound: 0, trailing: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SilenceBounds.analyze(url) == nil)
    }

    @Test("a quiet ending above the threshold is kept")
    func quietTailKept() throws {
        // −40 dBFS: quiet, but music. Must not be treated as silence.
        let url = try file(leading: 0, sound: 3, trailing: 0, amplitude: 0.01)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try SilenceBounds.analyze(url) == nil)
    }
}
