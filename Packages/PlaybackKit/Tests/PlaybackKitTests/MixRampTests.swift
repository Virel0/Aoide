import Foundation
import Testing
@testable import PlaybackKit

@Suite("Fade ramps")
struct MixRampTests {
    @Test("A fade is laid down end to end, with no gaps")
    func covers() {
        let segments = MixRamp.segments(seconds: 8, curve: MixCurve.incoming)
        #expect(segments.count == MixRamp.steps)
        #expect(segments.first?.start == 0)
        #expect(abs((segments.last?.end ?? 0) - 8) < 1e-9)
        for (a, b) in zip(segments, segments.dropFirst()) {
            #expect(abs(a.end - b.start) < 1e-9)
            // The level a segment leaves off at is the one the next picks up.
            #expect(abs(a.to - b.from) < 1e-9)
        }
    }

    @Test("It runs from silence to full, and back")
    func endpoints() {
        let into = MixRamp.segments(seconds: 4, curve: MixCurve.incoming)
        #expect(abs((into.first?.from ?? 1) - 0) < 1e-9)
        #expect(abs((into.last?.to ?? 0) - 1) < 1e-9)

        let out = MixRamp.segments(seconds: 4, curve: MixCurve.outgoing)
        #expect(abs((out.first?.from ?? 0) - 1) < 1e-9)
        #expect(abs((out.last?.to ?? 1) - 0) < 1e-9)
    }

    @Test("Straight segments stay within a fifth of a decibel of the curve")
    func approximation() {
        let seconds = 8.0
        let segments = MixRamp.segments(seconds: seconds, curve: MixCurve.incoming)
        var worstDb = 0.0
        for segment in segments {
            // The mid-point of a straight line is where it strays furthest from a
            // curve that bends the same way throughout.
            let midProgress = (segment.start + segment.end) / 2 / seconds
            let straight = (segment.from + segment.to) / 2
            let curved = MixCurve.incoming(progress: midProgress)
            guard straight > 0, curved > 0 else { continue }
            worstDb = max(worstDb, abs(20 * log10(straight / curved)))
        }
        #expect(worstDb < 0.2)
    }

    @Test("A fade with no length is not a fade")
    func nothingToFade() {
        #expect(MixRamp.segments(seconds: 0, curve: MixCurve.incoming).isEmpty)
        #expect(MixRamp.segments(seconds: -1, curve: MixCurve.incoming).isEmpty)
        #expect(MixRamp.segments(seconds: .nan, curve: MixCurve.incoming).isEmpty)
        #expect(MixRamp.segments(seconds: 8, steps: 0, curve: MixCurve.incoming).isEmpty)
    }
}
