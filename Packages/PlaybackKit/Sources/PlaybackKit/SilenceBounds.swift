import AVFoundation
import Foundation

/// Where the sound in a file actually starts and stops.
///
/// Gapless playback joins two files with no stall, and still leaves silence
/// between songs when the files themselves carry it: three seconds of nothing
/// after the last chord, two before the first note of the next. Trimming that is
/// a different job from gapless and is done here — the file is read once, the
/// first and last moments above a threshold are found, and the player is told
/// to play only that span. The handover stays stall-free because the player
/// treats the end point as the item's end.
public struct SilenceBounds: Codable, Hashable, Sendable {
    /// Where to begin. Zero when the file starts with sound.
    public let soundStart: Duration
    /// Where to stop. Equal to the file's length when it ends with sound.
    public let soundEnd: Duration

    public init(soundStart: Duration, soundEnd: Duration) {
        self.soundStart = soundStart
        self.soundEnd = soundEnd
    }

    /// Quieter than this is silence: −55 dBFS, well under a fade's tail but above
    /// the noise floor of a vinyl rip, so a quiet ending is kept and dead air is
    /// not.
    public static let threshold: Float = 0.00178

    /// Kept on either side of the sound, so a note's attack is never clipped and a
    /// reverb tail is not cut mid-decay.
    public static let leadMargin: Duration = .milliseconds(60)
    public static let tailMargin: Duration = .milliseconds(200)

    /// Trimming less than this is not worth the seek; the file is left alone.
    public static let minimumTrim: Duration = .milliseconds(300)

    /// The sound's span in `url`, or nil when there is nothing worth trimming: a
    /// file that starts and ends with sound, or one with no sound at all.
    ///
    /// Synchronous and reads the whole file: call it off the main actor.
    public static func analyze(_ url: URL) throws -> SilenceBounds? {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let rate = file.processingFormat.sampleRate
        let total = file.length
        guard total > 0, rate > 0 else { return nil }

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        let channels = Int(file.processingFormat.channelCount)

        var firstLoud: AVAudioFramePosition?
        var lastLoud: AVAudioFramePosition?
        var position: AVAudioFramePosition = 0

        while position < total {
            try file.read(into: buffer, frameCount: chunk)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for frame in 0..<frames {
                var loud = false
                for channel in 0..<channels where abs(data[channel][frame]) > threshold {
                    loud = true
                    break
                }
                if loud {
                    let at = position + AVAudioFramePosition(frame)
                    if firstLoud == nil { firstLoud = at }
                    lastLoud = at
                }
            }
            position += AVAudioFramePosition(frames)
        }

        guard let firstLoud, let lastLoud else { return nil }
        let length = seconds(total, rate)
        let start = max(.zero, seconds(firstLoud, rate) - leadMargin)
        let end = min(length, seconds(lastLoud, rate) + tailMargin)

        guard start >= minimumTrim || length - end >= minimumTrim else { return nil }
        return SilenceBounds(soundStart: start, soundEnd: end)
    }

    private static func seconds(_ frames: AVAudioFramePosition, _ rate: Double) -> Duration {
        .milliseconds(Int64((Double(frames) / rate * 1000).rounded()))
    }
}
