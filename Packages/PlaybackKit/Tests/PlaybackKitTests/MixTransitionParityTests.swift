import Foundation
import Testing
@testable import PlaybackKit

/// One pair of tracks and the handover both apps must plan for it.
private struct ParityCase: Sendable, CustomTestStringConvertible {
    let why: String
    let outgoing: MixTrack
    let incoming: MixTrack
    let automix: Bool
    let albumLock: Bool
    let kind: String
    let overlapSeconds: Double

    var testDescription: String { why }
}

private func track(
    album: String = "Album",
    number: Int? = nil,
    seconds: Double? = 240,
    bpm: Double? = nil,
    stability: Double? = nil,
    sound: SilenceBounds? = nil
) -> MixTrack {
    MixTrack(
        album: album,
        trackNumber: number,
        duration: seconds.map { Duration.seconds($0) },
        sound: sound,
        bpm: bpm,
        bpmStability: stability
    )
}

private func kindOf(_ transition: MixTransition) -> String {
    switch transition {
    case .gapless: "gapless"
    case .cut: "cut"
    case .blend: "blend"
    }
}

/// The same thirty-one pairs the desktop plans, with the same thirty-one plans.
///
/// "Both apps mix the same way" is a claim, and this table is the only thing that
/// makes it one: it is duplicated verbatim in the desktop's
/// `mix-transition-parity.test.ts`, so either side changing a constant, a
/// tolerance or an ordering breaks its own copy. The overlaps are exact numbers
/// rather than "about eight seconds" on purpose — two planners a tenth of a
/// second apart are still two planners.
private let parityTable: [ParityCase] = [
    ParityCase(
        why: "the mixer off leaves the handover alone",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", bpm: 128),
        automix: false,
        albumLock: true,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "an album run is gapless with the mixer off too",
        outgoing: track(album: "Dark Side", number: 4),
        incoming: track(album: "Dark Side", number: 5),
        automix: false,
        albumLock: true,
        kind: "gapless",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "album lock is the mixer’s off-switch, never a second mixer",
        outgoing: track(album: "Dark Side", number: 4),
        incoming: track(album: "Dark Side", number: 5),
        automix: false,
        albumLock: false,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "a record that segues is never handed to the mixer",
        outgoing: track(album: "Dark Side", number: 4, bpm: 90),
        incoming: track(album: "Dark Side", number: 5, bpm: 140),
        automix: true,
        albumLock: true,
        kind: "gapless",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "album lock off lets the mixer work across a record",
        outgoing: track(album: "Dark Side", number: 4, bpm: 128),
        incoming: track(album: "Dark Side", number: 5, bpm: 128),
        automix: true,
        albumLock: false,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "agreeing tempi earn the long blend",
        outgoing: track(bpm: 124),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "half time is one groove counted twice",
        outgoing: track(bpm: 85),
        incoming: track(album: "Other", bpm: 170),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "two octaves apart is still one groove",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", bpm: 32),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "genuinely different speeds get the short blend",
        outgoing: track(bpm: 100),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "six per cent apart is inside the tolerance",
        outgoing: track(bpm: 120),
        incoming: track(album: "Other", bpm: 127.2),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "just past six per cent is outside it",
        outgoing: track(bpm: 120),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "nothing measured is not an agreement",
        outgoing: track(),
        incoming: track(album: "Other"),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "one measured tempo is not an agreement either",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other"),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "a zero tempo is not a measurement",
        outgoing: track(bpm: 0),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "out of order on one record is not a run",
        outgoing: track(album: "Dark Side", number: 9, bpm: 128),
        incoming: track(album: "Dark Side", number: 1, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "the next number on another record is not a run",
        outgoing: track(album: "Dark Side", number: 9, bpm: 128),
        incoming: track(album: "Wish You Were Here", number: 10, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "two untitled albums are not one record",
        outgoing: track(album: "", number: 4, bpm: 128),
        incoming: track(album: "", number: 5, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "one album without track numbers is not a run",
        outgoing: track(album: "Dark Side", bpm: 128),
        incoming: track(album: "Dark Side", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "a short track keeps three quarters of itself",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: 20, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 5
    ),
    ParityCase(
        why: "exactly a quarter of the shorter track is allowed",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: 32, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "a short blend under the share is not lengthened to it",
        outgoing: track(bpm: 100),
        incoming: track(album: "Other", seconds: 20, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "two seconds of overlap is still a transition",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: 8, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 2
    ),
    ParityCase(
        why: "a hair under two seconds is not",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: 7.9, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "a sting is too short to fade at all",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: 6, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "an unknown length ahead is a cut, not a guess",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", seconds: nil, bpm: 128),
        automix: true,
        albumLock: true,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "an unknown length behind is a cut too",
        outgoing: track(seconds: nil, bpm: 128),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "cut",
        overlapSeconds: 0
    ),
    ParityCase(
        why: "measured sound, not file length, is what there is to fade",
        outgoing: track(bpm: 128),
        incoming: track(
            album: "Other",
            seconds: 120,
            bpm: 128,
            sound: SilenceBounds(soundStart: .seconds(100), soundEnd: .seconds(110))
        ),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 2.5
    ),
    ParityCase(
        why: "a track whose tempo does not hold is nothing to match to",
        outgoing: track(bpm: 128, stability: 0.2),
        incoming: track(album: "Other", bpm: 128),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "and neither is one coming up",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", bpm: 128, stability: 0.4),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 4
    ),
    ParityCase(
        why: "half the windows agreeing is steady enough",
        outgoing: track(bpm: 128, stability: 0.5),
        incoming: track(album: "Other", bpm: 128, stability: 0.5),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
    ParityCase(
        why: "an unmeasured stability is not held against a track",
        outgoing: track(bpm: 128),
        incoming: track(album: "Other", bpm: 128, stability: 0.9),
        automix: true,
        albumLock: true,
        kind: "blend",
        overlapSeconds: 8
    ),
]

@Suite("Mix transition parity")
struct MixTransitionParityTests {
    @Test("plans the desktop's table identically", arguments: parityTable)
    fileprivate func parityWithDesktop(_ row: ParityCase) {
        let plan = MixPlanner.plan(
            from: row.outgoing,
            to: row.incoming,
            automix: row.automix,
            albumLock: row.albumLock
        )
        #expect(kindOf(plan) == row.kind)
        #expect(abs(plan.overlap.seconds - row.overlapSeconds) < 1e-9)
    }

    @Test("answers every case in the table")
    func everyCase() {
        #expect(parityTable.count == 31)
    }
}
