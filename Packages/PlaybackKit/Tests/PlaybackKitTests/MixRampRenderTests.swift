import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The ramps put through AVFoundation itself, rather than checked as arithmetic.
///
/// The arithmetic is covered next door in `MixRampTests`; what this suite is for
/// is the part that cannot be reasoned about — whether the times we hand
/// `setVolumeRamp` land where we meant them to in the asset's own timeline.
/// Getting that frame wrong does not produce an error anywhere: it produces a
/// crossfade that either never happens or happens over the wrong four seconds,
/// which is only ever discovered by listening.
///
/// Rendered offline with `AVAssetExportSession`, because that runs the same audio
/// mix the player would and hands back something measurable.
@Suite("Fades as rendered")
struct MixRampRenderTests {
    private static let rate = 44_100.0
    private static let amplitude: Float = 0.5

    /// A steady tone, so any change in level is the fade and nothing else.
    private func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ramp-\(UUID()).m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false)!
        let writer = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: Self.rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitDepthHintKey: 16,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = Int(seconds * Self.rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for i in 0..<total {
            buffer.floatChannelData![0][i] = Self.amplitude * Float(sin(2 * .pi * 440 * Double(i) / Self.rate))
        }
        try writer.write(from: buffer)
        writer.close()
        return url
    }

    private func render(_ asset: AVURLAsset, mix: AVAudioMix) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rendered-\(UUID()).m4a")
        let session = try #require(AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A))
        session.audioMix = mix
        try await session.export(to: url, as: .m4a)
        return url
    }

    /// RMS level of each `window` seconds of a file, in decibels relative to the
    /// tone's own unfaded level.
    private func levels(of url: URL, window: Double) throws -> [Double] {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        let perWindow = Int(window * file.processingFormat.sampleRate)
        // A steady sine's RMS is its amplitude over root two; that is 0 dB here.
        let reference = Double(Self.amplitude) / 2.0.squareRoot()

        var levels: [Double] = []
        var start = 0
        while start + perWindow <= Int(buffer.frameLength) {
            var sum = 0.0
            for i in start..<(start + perWindow) {
                sum += Double(samples[i]) * Double(samples[i])
            }
            let rms = (sum / Double(perWindow)).squareRoot()
            levels.append(20 * log10(max(rms, 1e-9) / reference))
            start += perWindow
        }
        return levels
    }

    /// What the fade should measure in each window, worked out from the same curve
    /// the ramps are built from — integrated across the window rather than sampled
    /// at its middle, because that is what an RMS reading of it is.
    private func expected(window index: Int, window: Double, fadeStart: Double, seconds: Double, curve: (Double) -> Double) -> Double {
        let steps = 200
        var power = 0.0
        for step in 0..<steps {
            let t = (Double(index) + (Double(step) + 0.5) / Double(steps)) * window
            let progress = (t - fadeStart) / seconds
            let gain = curve(min(1, max(0, progress)))
            power += gain * gain
        }
        return 10 * log10(power / Double(steps))
    }

    @Test("A fade-in starts from silence and is done when the blend is")
    func fadeIn() async throws {
        let source = try tone(seconds: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let mix = try #require(MixRamp.fadeIn(track: track, startingAt: .zero, seconds: 4))

        let rendered = try await render(asset, mix: mix)
        defer { try? FileManager.default.removeItem(at: rendered) }
        let window = 0.5
        let levels = try levels(of: rendered, window: window)

        for (index, level) in levels.enumerated() {
            let expected = expected(window: index, window: window, fadeStart: 0, seconds: 4, curve: MixCurve.incoming)
            #expect(abs(level - expected) < 1.5, "window \(index): \(level) dB, expected \(expected) dB")
        }
        #expect(levels[0] < -18)
        // Done fading by four seconds, and full level from there on.
        #expect(abs(levels[8]) < 0.5)
        #expect(abs(levels[19]) < 0.5)
    }

    @Test("A fade that begins partway through is silent until it does")
    func offsetFadeIn() async throws {
        let source = try tone(seconds: 10)
        defer { try? FileManager.default.removeItem(at: source) }
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        // What a track whose leading silence has been measured gets: the fade
        // starts where the sound does, three seconds in.
        let mix = try #require(MixRamp.fadeIn(track: track, startingAt: CMTime(seconds: 3, preferredTimescale: 600), seconds: 4))

        let rendered = try await render(asset, mix: mix)
        defer { try? FileManager.default.removeItem(at: rendered) }
        let levels = try levels(of: rendered, window: 0.5)

        // Nothing at all before the fade — the level is pinned down at the start
        // of the item, not merely left wherever the pipeline had it.
        for level in levels.prefix(6) {
            #expect(level < -60, "expected silence before the fade, measured \(level) dB")
        }
        for index in 7..<14 {
            let expected = expected(window: index, window: 0.5, fadeStart: 3, seconds: 4, curve: MixCurve.incoming)
            #expect(abs(levels[index] - expected) < 1.5, "window \(index): \(levels[index]) dB, expected \(expected) dB")
        }
        // Full level from seven seconds on.
        #expect(abs(levels[15]) < 0.5)
        #expect(abs(levels[19]) < 0.5)
    }
}
