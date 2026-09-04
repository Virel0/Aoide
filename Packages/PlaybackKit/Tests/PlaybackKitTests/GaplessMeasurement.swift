import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// How long the player's own clock stalls between two local Apple Lossless files.
///
/// Not a listening test — nothing here reaches a speaker — but the player's
/// timeline stalling at a boundary is the transition's cost, and it is what a
/// listener hears as a gap. Measured under the settings the engine could choose
/// between, so the choice is made on numbers.
@Suite("Gapless measurement", .serialized)
struct GaplessMeasurement {
    private static let sampleRate = 44_100.0
    private static let seconds = 1.5

    private func tone(_ name: String, keepFLAC: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let flac = dir.appendingPathComponent("gap-\(name)-\(UUID()).flac")
        let alac = dir.appendingPathComponent("gap-\(name)-\(UUID()).m4a")
        let frames = AVAudioFrameCount(Self.sampleRate * Self.seconds)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: flac,
            settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16],
            commonFormat: .pcmFormatInt16, interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            let v = Int16(8000 * sin(2 * .pi * 440 * Double(i) / Self.sampleRate))
            buffer.int16ChannelData![0][i] = v
            buffer.int16ChannelData![1][i] = v
        }
        try file.write(from: buffer)
        file.close()
        if keepFLAC { return flac }
        try LosslessConverter.convertFLAC(at: flac, to: alac)
        try? FileManager.default.removeItem(at: flac)
        return alac
    }

    struct Setting: CustomStringConvertible {
        let waits: Bool
        let forwardBuffer: TimeInterval
        var flac = false
        var description: String { "\(flac ? "flac" : "alac") waits=\(waits) forwardBuffer=\(forwardBuffer)" }
    }

    /// Wall-clock milliseconds between the first item's last observed tick and the
    /// second item's first tick past zero, less the media time that elapsed.
    @MainActor
    private func stall(_ setting: Setting) async throws -> Double {
        let a = try tone("a", keepFLAC: setting.flac), b = try tone("b", keepFLAC: setting.flac)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let items = [AVPlayerItem(url: a), AVPlayerItem(url: b)]
        for item in items { item.preferredForwardBufferDuration = setting.forwardBuffer }
        let player = AVQueuePlayer(items: items)
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = setting.waits
        player.volume = 0

        final class Probe: @unchecked Sendable {
            var lastOfFirst: (wall: Double, media: Double)?
            var firstOfSecond: (wall: Double, media: Double)?
            var second: AVPlayerItem?
        }
        let probe = Probe()
        probe.second = items[1]
        let observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 1000), queue: .main) { time in
            let now = Date().timeIntervalSince1970
            let media = time.seconds
            if player.currentItem === probe.second {
                if probe.firstOfSecond == nil, media > 0 { probe.firstOfSecond = (now, media) }
            } else if media > 0 {
                probe.lastOfFirst = (now, media)
            }
        }
        player.play()
        let deadline = Date().addingTimeInterval(Self.seconds * 2 + 3)
        while probe.firstOfSecond == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        player.removeTimeObserver(observer)
        player.pause()
        guard let end = probe.lastOfFirst, let start = probe.firstOfSecond else { return .nan }
        // Media that played in that wall interval: the tail of the first item plus
        // the head of the second. Anything beyond it is the transition itself.
        let mediaElapsed = (Self.seconds - end.media) + start.media
        return ((start.wall - end.wall) - mediaElapsed) * 1000
    }

    @Test("stall at the boundary, per setting")
    @MainActor
    func measure() async throws {
        let settings = [
            Setting(waits: true, forwardBuffer: 600),   // the engine today
            Setting(waits: true, forwardBuffer: 0),
            Setting(waits: false, forwardBuffer: 600),
            Setting(waits: false, forwardBuffer: 0),
            Setting(waits: true, forwardBuffer: 600, flac: true),
            Setting(waits: true, forwardBuffer: 0, flac: true),
        ]
        var lines: [String] = []
        for setting in settings {
            var samples: [Double] = []
            for _ in 0..<3 { samples.append(try await stall(setting)) }
            let text = samples.map { $0.isNaN ? "n/a" : String(format: "%.0f", $0) }.joined(separator: " ")
            lines.append("\(setting): \(text) ms")
        }
        print("GAPLESS\n" + lines.joined(separator: "\n"))
        #expect(!lines.isEmpty)
    }
}
