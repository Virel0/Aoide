import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The converter's output is played by `AVPlayer`, not read back by `AVAudioFile`
/// — so what matters is whether an `AVAsset` will have it.
@Suite("Converted files are playable")
struct LosslessPlayabilityTests {
    @Test("AVAsset opens the converted file, finds an audio track, and agrees on the length")
    func playable() async throws {
        let flac = FileManager.default.temporaryDirectory.appendingPathComponent("play-\(UUID()).flac")
        let alac = FileManager.default.temporaryDirectory.appendingPathComponent("play-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: flac); try? FileManager.default.removeItem(at: alac) }

        let frames: AVAudioFrameCount = 44_100 * 3
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44_100, channels: 2, interleaved: false)!
        let writer = try AVAudioFile(
            forWriting: flac,
            settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16],
            commonFormat: .pcmFormatInt16, interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        try writer.write(from: buffer)
        writer.close()

        try LosslessConverter.convertFLAC(at: flac, to: alac)

        let asset = AVURLAsset(url: alac)
        let (isPlayable, tracks, duration) = try await asset.load(.isPlayable, .tracks, .duration)
        #expect(isPlayable)
        #expect(tracks.contains { $0.mediaType == .audio })
        #expect(abs(duration.seconds - 3) < 0.01, "duration \(duration.seconds)")
    }
}
