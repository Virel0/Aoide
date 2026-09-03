import AVFoundation
import Foundation

/// Rewrites a FLAC file as Apple Lossless, sample for sample.
///
/// Apple's FLAC decoder pads the last block of a file out to a whole block, which
/// leaves a short silence — measured at about 57ms — between two tracks that were
/// mastered to run together. Its ALAC decoder does not, because an `.m4a` carries
/// the exact frame count and the player trims to it. Both are lossless, so the
/// conversion changes nothing but the container: the same samples, gapless.
///
/// Done once, at download time, on the phone. Asking the server to transcode would
/// work too, but a downloaded file is kept forever and re-fetching every download
/// to fix a gap is a worse deal than a few seconds of CPU per track.
public enum LosslessConverter {
    public enum Failure: Error, Equatable {
        case notFLAC
        case unreadable
    }

    /// Frames read and written per pass. Large enough that a track is a few dozen
    /// passes; small enough that memory stays a few megabytes.
    private static let framesPerPass: AVAudioFrameCount = 65_536

    /// Converts `source` into an Apple Lossless `.m4a` at `destination`, replacing
    /// anything already there. Synchronous and CPU-bound: call it off the main
    /// actor.
    public static func convertFLAC(at source: URL, to destination: URL) throws {
        let probe = try AVAudioFile(forReading: source)
        let description = probe.fileFormat.streamDescription.pointee
        guard description.mFormatID == kAudioFormatFLAC else { throw Failure.notFLAC }
        let depth = bitDepth(of: description)

        // Decoded at the file's own depth. Going through 32-bit integers and back
        // down cost one bit of the lowest place on the way — measured, not
        // theorised — which is not "lossless" by any definition worth the name.
        let pcm: AVAudioCommonFormat = depth == 16 ? .pcmFormatInt16 : .pcmFormatInt32
        let input = try AVAudioFile(forReading: source, commonFormat: pcm, interleaved: false)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: input.fileFormat.sampleRate,
            AVNumberOfChannelsKey: Int(input.fileFormat.channelCount),
            // Told the source's real depth, or a 16-bit rip would be padded into a
            // 32-bit ALAC twice the size for no more information.
            AVEncoderBitDepthHintKey: depth,
        ]

        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: pcm,
            interleaved: false
        )

        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: framesPerPass) else {
            throw Failure.unreadable
        }

        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: framesPerPass)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
        }
    }

    /// FLAC shares Apple Lossless's format flags, which carry the source bit depth.
    /// A file that says nothing is taken as CD audio.
    static func bitDepth(of description: AudioStreamBasicDescription) -> Int {
        // The depth is a small number in the low bits, not a bit mask: 1, 2, 3, 4.
        switch description.mFormatFlags & 0x7 {
        case AudioFormatFlags(kAppleLosslessFormatFlag_16BitSourceData): 16
        case AudioFormatFlags(kAppleLosslessFormatFlag_20BitSourceData): 20
        case AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData): 24
        case AudioFormatFlags(kAppleLosslessFormatFlag_32BitSourceData): 32
        default: 16
        }
    }
}
