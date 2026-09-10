import Foundation
import Testing
@testable import PlaybackKit

private func track(
    album: String = "Album",
    number: Int? = nil,
    seconds: Double = 240,
    bpm: Double? = nil
) -> MixTrack {
    MixTrack(
        album: album,
        trackNumber: number,
        duration: .seconds(seconds),
        sound: nil,
        bpm: bpm
    )
}

@Suite("Mix transitions")
struct MixTransitionTests {
    @Test("AutoMix off leaves the handover alone")
    func automixOff() {
        let plan = MixPlanner.plan(from: track(bpm: 128), to: track(album: "Other", bpm: 128), automix: false)
        #expect(plan == .cut)
        #expect(plan.overlap == .zero)
    }

    @Test("Agreeing tempi earn the long blend")
    func matched() {
        let plan = MixPlanner.plan(from: track(bpm: 124), to: track(album: "Other", bpm: 128), automix: true)
        #expect(plan == .blend(MixPlanner.matchedBlend))
    }

    @Test("Half time counts as agreement")
    func halfTime() {
        #expect(MixPlanner.tempiAgree(85, 170))
        #expect(MixPlanner.tempiAgree(170, 86))
        #expect(MixPlanner.tempiAgree(128, 32))
    }

    @Test("Genuinely different speeds do not")
    func mismatched() {
        #expect(!MixPlanner.tempiAgree(100, 128))
        let plan = MixPlanner.plan(from: track(bpm: 100), to: track(album: "Other", bpm: 128), automix: true)
        #expect(plan == .blend(MixPlanner.unmatchedBlend))
    }

    @Test("An unmeasured tempo is not an agreeing one")
    func unmeasured() {
        #expect(!MixPlanner.tempiAgree(nil, 128))
        #expect(!MixPlanner.tempiAgree(128, nil))
        #expect(!MixPlanner.tempiAgree(0, 128))
        let plan = MixPlanner.plan(from: track(), to: track(album: "Other"), automix: true)
        #expect(plan == .blend(MixPlanner.unmatchedBlend))
    }

    @Test("Two tracks of one album run straight on, mixer or not")
    func albumRun() {
        let one = track(album: "Dark Side", number: 4, bpm: 90)
        let two = track(album: "Dark Side", number: 5, bpm: 140)
        #expect(MixPlanner.plan(from: one, to: two, automix: true) == .gapless)
        #expect(MixPlanner.plan(from: one, to: two, automix: false) == .gapless)
    }

    @Test("Out of order, or a different record, is not a run")
    func notAnAlbumRun() {
        let nine = track(album: "Dark Side", number: 9, bpm: 128)
        let one = track(album: "Dark Side", number: 1, bpm: 128)
        #expect(MixPlanner.plan(from: nine, to: one, automix: true) == .blend(MixPlanner.matchedBlend))

        let elsewhere = track(album: "Wish You Were Here", number: 10, bpm: 128)
        #expect(MixPlanner.plan(from: nine, to: elsewhere, automix: true) == .blend(MixPlanner.matchedBlend))

        let untitled = track(album: "", number: 4, bpm: 128)
        let alsoUntitled = track(album: "", number: 5, bpm: 128)
        #expect(MixPlanner.plan(from: untitled, to: alsoUntitled, automix: true) == .blend(MixPlanner.matchedBlend))
    }

    @Test("Album lock off lets the mixer work across a record")
    func albumLockOff() {
        let one = track(album: "Dark Side", number: 4, bpm: 128)
        let two = track(album: "Dark Side", number: 5, bpm: 128)
        #expect(MixPlanner.plan(from: one, to: two, automix: true, albumLock: false) == .blend(MixPlanner.matchedBlend))
        // With the mixer off it is still a cut, not a fade — album lock is the
        // mixer's off-switch, not a second mixer.
        #expect(MixPlanner.plan(from: one, to: two, automix: false, albumLock: false) == .cut)
    }

    @Test("A short track keeps most of itself")
    func shortTrackShrinksTheBlend() {
        let interlude = track(album: "Other", seconds: 20, bpm: 128)
        let plan = MixPlanner.plan(from: track(bpm: 128), to: interlude, automix: true)
        #expect(plan == .blend(.seconds(5)))
    }

    @Test("Too short to fade is a cut")
    func tooShortToFade() {
        let sting = track(album: "Other", seconds: 6, bpm: 128)
        #expect(MixPlanner.plan(from: track(bpm: 128), to: sting, automix: true) == .cut)
    }

    @Test("An unknown length is a cut, not a guess")
    func unknownLength() {
        let unknown = MixTrack(album: "Other", trackNumber: nil, duration: nil, sound: nil, bpm: 128)
        #expect(MixPlanner.plan(from: track(bpm: 128), to: unknown, automix: true) == .cut)
        #expect(MixPlanner.plan(from: unknown, to: track(bpm: 128), automix: true) == .cut)
    }

    @Test("Measured sound, not file length, is what there is to fade")
    func trimmedTrackFadesOverItsSound() {
        // Two minutes of file, ten seconds of sound: a long lead-out of silence
        // is not material to blend over.
        let mostlySilence = MixTrack(
            album: "Other",
            trackNumber: nil,
            duration: .seconds(120),
            sound: SilenceBounds(soundStart: .seconds(100), soundEnd: .seconds(110)),
            bpm: 128
        )
        #expect(MixPlanner.plan(from: track(bpm: 128), to: mostlySilence, automix: true) == .blend(.seconds(2.5)))
    }
}

@Suite("Crossfade curve")
struct MixCurveTests {
    @Test("Starts and ends where a fade should")
    func endpoints() {
        #expect(abs(MixCurve.outgoing(progress: 0) - 1) < 1e-9)
        #expect(abs(MixCurve.outgoing(progress: 1) - 0) < 1e-9)
        #expect(abs(MixCurve.incoming(progress: 0) - 0) < 1e-9)
        #expect(abs(MixCurve.incoming(progress: 1) - 1) < 1e-9)
    }

    @Test("Holds a constant power across the handover")
    func constantPower() {
        for step in 0...20 {
            let progress = Double(step) / 20
            let out = MixCurve.outgoing(progress: progress)
            let into = MixCurve.incoming(progress: progress)
            #expect(abs(out * out + into * into - 1) < 1e-9)
        }
        // The midpoint is where a linear fade would dip: both sides sit at 0.707,
        // not 0.5.
        #expect(abs(MixCurve.outgoing(progress: 0.5) - 0.7071067811865476) < 1e-9)
    }

    @Test("A progress outside the fade stays inside the fade")
    func clamped() {
        #expect(MixCurve.outgoing(progress: -1) == 1)
        #expect(MixCurve.incoming(progress: 2) == 1)
        #expect(MixCurve.incoming(progress: .nan) == 0)
    }
}

@Suite("Tempo that does not hold")
struct MixStabilityTests {
    private func track(bpm: Double?, stability: Double?, album: String = "Album") -> MixTrack {
        MixTrack(album: album, duration: .seconds(240), bpm: bpm, bpmStability: stability)
    }

    @Test("A wandering tempo is not something to match to")
    func unstableRefusesTheLongBlend() {
        let steady = track(bpm: 128, stability: 1.0)
        let ramping = track(bpm: 128, stability: 0.1, album: "Other")
        #expect(MixPlanner.plan(from: steady, to: ramping, automix: true) == .blend(MixPlanner.unmatchedBlend))
        #expect(MixPlanner.plan(from: ramping, to: steady, automix: true) == .blend(MixPlanner.unmatchedBlend))
    }

    @Test("Two steady tracks at one tempo still earn it")
    func steadyKeepsTheLongBlend() {
        let one = track(bpm: 128, stability: 0.9)
        let two = track(bpm: 126, stability: 0.62, album: "Other")
        #expect(MixPlanner.plan(from: one, to: two, automix: true) == .blend(MixPlanner.matchedBlend))
    }

    @Test("A server that never measured it is not held against the track")
    func unmeasuredStabilityIsNotAFailure() {
        let one = track(bpm: 128, stability: nil)
        let two = track(bpm: 128, stability: nil, album: "Other")
        #expect(MixPlanner.plan(from: one, to: two, automix: true) == .blend(MixPlanner.matchedBlend))
        #expect(MixPlanner.holds(nil))
    }
}
