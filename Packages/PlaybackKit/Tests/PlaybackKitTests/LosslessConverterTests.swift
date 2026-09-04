import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// The whole point of the conversion is that it changes nothing audible and keeps
/// the exact length — so those are the two things checked, sample by sample.
@Suite("Lossless conversion")
struct LosslessConverterTests {
    private static let sampleRate = 44_100.0
    private static let frames: AVAudioFrameCount = 44_100 + 1_234   // deliberately not a block multiple

    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aoide-lossless-\(UUID().uuidString)-\(name)")
    }

    /// A stereo test tone written as FLAC by Apple's own encoder, handed integer
    /// samples at the requested depth: given floats, the encoder ignores the depth
    /// hint and writes 24-bit, which would make the fixture lie about itself.
    private func writeFLAC(to url: URL, bitDepth: Int = 16) throws {
        let pcm: AVAudioCommonFormat = bitDepth == 16 ? .pcmFormatInt16 : .pcmFormatInt32
        let format = AVAudioFormat(commonFormat: pcm, sampleRate: Self.sampleRate, channels: 2, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitDepthHintKey: bitDepth,
            ],
            commonFormat: pcm,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frames)!
        buffer.frameLength = Self.frames
        for frame in 0..<Int(Self.frames) {
            let t = Double(frame) / Self.sampleRate
            let left = 0.5 * sin(2 * .pi * 440 * t)
            let right = 0.25 * sin(2 * .pi * 660 * t)
            if bitDepth == 16 {
                buffer.int16ChannelData![0][frame] = Int16(left * 32_767)
                buffer.int16ChannelData![1][frame] = Int16(right * 32_767)
            } else {
                // 24-bit samples travel left-justified in 32-bit words.
                buffer.int32ChannelData![0][frame] = Int32(left * 8_388_607) << 8
                buffer.int32ChannelData![1][frame] = Int32(right * 8_388_607) << 8
            }
        }
        try file.write(from: buffer)
        // Closed before it is read back: the header is only finished on close, and
        // an open writer's file cannot be opened for reading.
        file.close()
        // The fixture must be what it claims, or the tests below prove nothing.
        let check = try AVAudioFile(forReading: url)
        #expect(LosslessConverter.bitDepth(of: check.fileFormat.streamDescription.pointee) == bitDepth)
    }

    private func decode(_ url: URL) throws -> (frames: AVAudioFrameCount, samples: [Float]) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
        return (buffer.frameLength, left + right)
    }

    @Test("keeps every sample and the exact length", arguments: [16, 24])
    func exact(bitDepth: Int) throws {
        let flac = scratch("in.flac")
        let alac = scratch("out.m4a")
        defer { try? FileManager.default.removeItem(at: flac); try? FileManager.default.removeItem(at: alac) }
        try writeFLAC(to: flac, bitDepth: bitDepth)

        try LosslessConverter.convertFLAC(at: flac, to: alac)

        let before = try decode(flac)
        let after = try decode(alac)
        #expect(after.frames == Self.frames)
        #expect(after.frames == before.frames)
        #expect(after.samples.count == before.samples.count)
        let worst = zip(before.samples, after.samples).map { abs($0 - $1) }.max() ?? 1
        // Both are 16-bit lossless of the same samples: any difference at all is
        // a conversion that lost something.
        #expect(worst == 0, "largest sample difference \(worst)")
    }

    @Test("the result is Apple Lossless at the source's bit depth")
    func format() throws {
        let flac = scratch("in.flac")
        let alac = scratch("out.m4a")
        defer { try? FileManager.default.removeItem(at: flac); try? FileManager.default.removeItem(at: alac) }
        try writeFLAC(to: flac)

        try LosslessConverter.convertFLAC(at: flac, to: alac)

        let written = try AVAudioFile(forReading: alac)
        let description = written.fileFormat.streamDescription.pointee
        #expect(description.mFormatID == kAudioFormatAppleLossless)
        #expect(LosslessConverter.bitDepth(of: description) == 16)

        let hiRes = scratch("in24.flac")
        let hiResOut = scratch("out24.m4a")
        defer { try? FileManager.default.removeItem(at: hiRes); try? FileManager.default.removeItem(at: hiResOut) }
        try writeFLAC(to: hiRes, bitDepth: 24)
        try LosslessConverter.convertFLAC(at: hiRes, to: hiResOut)
        let hiResWritten = try AVAudioFile(forReading: hiResOut)
        #expect(LosslessConverter.bitDepth(of: hiResWritten.fileFormat.streamDescription.pointee) == 24)
        #expect(written.fileFormat.sampleRate == Self.sampleRate)
        #expect(written.fileFormat.channelCount == 2)
    }

    @Test("refuses a file that is not FLAC rather than re-encoding it")
    func refusesOthers() throws {
        let alac = scratch("already.m4a")
        let out = scratch("out.m4a")
        defer { try? FileManager.default.removeItem(at: alac); try? FileManager.default.removeItem(at: out) }
        let flac = scratch("in.flac")
        try writeFLAC(to: flac)
        try LosslessConverter.convertFLAC(at: flac, to: alac)
        try? FileManager.default.removeItem(at: flac)

        #expect(throws: LosslessConverter.Failure.notFLAC) {
            try LosslessConverter.convertFLAC(at: alac, to: out)
        }
    }

    @Test("the scratch name keeps the container's extension, and is recognisable afterwards")
    func scratchNaming() {
        let destination = URL(fileURLWithPath: "/tmp/Downloads/abc123.m4a")
        let scratch = LosslessConverter.scratchURL(for: destination)
        #expect(scratch.pathExtension == "m4a", "the writer picks the container from this")
        #expect(scratch.lastPathComponent == "abc123.converting.m4a")
        #expect(LosslessConverter.isScratch(scratch))
        #expect(!LosslessConverter.isScratch(destination))
    }

    @Test("bit depth is read from the format flags, defaulting to sixteen")
    func bitDepth() {
        var description = AudioStreamBasicDescription()
        #expect(LosslessConverter.bitDepth(of: description) == 16)
        description.mFormatFlags = AudioFormatFlags(kAppleLosslessFormatFlag_24BitSourceData)
        #expect(LosslessConverter.bitDepth(of: description) == 24)
        description.mFormatFlags = AudioFormatFlags(kAppleLosslessFormatFlag_20BitSourceData)
        #expect(LosslessConverter.bitDepth(of: description) == 20)
        description.mFormatFlags = AudioFormatFlags(kAppleLosslessFormatFlag_32BitSourceData)
        #expect(LosslessConverter.bitDepth(of: description) == 32)
    }
}
