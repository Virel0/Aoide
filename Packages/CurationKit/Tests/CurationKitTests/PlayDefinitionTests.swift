import Foundation
import GRDB
import Testing
@testable import CurationKit

/// The two things that must never disagree about what a play is.
///
/// `CurationStore.stats` prints the number beside a track. `CurationStore.evaluate`
/// decides who is in "played more than five times". They are separate queries over
/// separate joins, and before these tests existed they were separate *definitions* —
/// one counting a listen with an unknown duration as a skip, the other never; one
/// reading the stored skip flag, the other recomputing it; one dating "last played"
/// from any event, the other from qualifying plays only.
///
/// None of that showed up as a failure, because each suite tested its own half. It
/// would have shown up as a play count of 6 next to a track that a "played more than 5
/// times" playlist refused to include, which is not a bug anyone can report usefully.
/// So the agreement itself is the thing under test here.
@Suite("One definition of a play")
struct PlayDefinitionTests {

    private let now: Millis = 1_700_000_000_000

    /// Durations chosen to exercise both halves of the rule and both fallbacks: unknown,
    /// the degenerate zero, tracks short enough that half of them is the binding
    /// threshold, and tracks long enough that four minutes is.
    private let durations: [Int?] = [nil, 0, 90_000, 180_000, 200_000, 600_000, 1_200_000]

    /// Listens sitting on and either side of every boundary the rule can produce:
    /// halves, fifths, the 240 s ceiling and the 48 s fallback fifth of it.
    private let listens = [
        0, 1, 17_999, 18_000, 29_999, 30_000, 44_999, 45_000, 47_999, 48_000,
        89_999, 90_000, 99_999, 100_000, 119_999, 120_000, 239_999, 240_000,
        300_000, 600_000, 1_200_000,
    ]

    private func caseId(_ duration: Int?, _ played: Int) -> String {
        // Zero-padded so the id sorts the way the numbers do, which makes a failing
        // set-difference readable rather than a wall of shuffled ids.
        String(format: "d%09d-p%09d", duration ?? -1, played)
    }

    /// One track per (duration, listen) pair, each with exactly one play event, so a
    /// track's play count is 1 if and only if that single listen qualified.
    private func matrix(classified: Bool) throws -> CurationStore {
        let store = try CurationStore.inMemory(deviceId: "phone")
        for duration in durations {
            for played in listens {
                let id = caseId(duration, played)
                try store.writeLocal { db in
                    try TrackRef(
                        jellyfinId: id, contentKey: id, title: id,
                        artist: "A", album: "A", durationMs: duration, lastSeenAt: now
                    ).insert(db)
                }
                if classified {
                    // Through the player's path: `PlayClassifier` runs and stamps
                    // `completed` and `skipped` onto the row.
                    try store.recordPlay(
                        jellyfinId: id, contentKey: id, startedAt: now - 1_000,
                        msPlayed: played, trackDurationMs: duration
                    )
                } else {
                    // The path a sync or an import takes: a finished event carrying
                    // neither verdict, which both queries must judge from its numbers.
                    try store.append(PlayEvent(
                        jellyfinId: id, contentKey: id, startedAt: now - 1_000,
                        endedAt: now, msPlayed: played, originDevice: "other"
                    ))
                }
            }
        }
        return store
    }

    /// Every id the smart evaluator says has exactly this count for `field`.
    private func smartSet(_ store: CurationStore, _ field: SmartRule.Field, _ count: Int) throws -> Set<String> {
        let rules = try SmartRules(rules: [SmartRule(field: field, op: .is, value: .number(count))])
        return Set(try store.evaluate(rules, asOf: now))
    }

    /// Every id `stats` says has exactly this count.
    private func statsSet(
        _ store: CurationStore,
        _ count: Int,
        _ pick: (TrackStats) -> Int
    ) throws -> Set<String> {
        var ids: [String] = []
        for duration in durations {
            for played in listens { ids.append(caseId(duration, played)) }
        }
        return Set(try store.stats(jellyfinIds: ids).values.filter { pick($0) == count }.map(\.jellyfinId))
    }

    @Test("the play count beside a track and the play count a smart rule reads are the same number", arguments: [true, false])
    func playCountsAgree(classified: Bool) throws {
        let store = try matrix(classified: classified)
        for count in [0, 1] {
            #expect(try statsSet(store, count, \.playCount) == smartSet(store, .playCount, count))
        }
    }

    @Test("the skip count beside a track and the skip count a smart rule reads are the same number", arguments: [true, false])
    func skipCountsAgree(classified: Bool) throws {
        let store = try matrix(classified: classified)
        for count in [0, 1] {
            #expect(try statsSet(store, count, \.skipCount) == smartSet(store, .skipCount, count))
        }
    }

    /// The SQL runs against the cached duration; the classifier ran against the
    /// player's. Where those are the same number — which is every case here — the two
    /// must reach the identical verdict, or a track's play count would depend on which
    /// of them you happened to ask.
    @Test("the SQL and the Swift classifier reach the same verdict on every boundary")
    func sqlAgreesWithClassifier() throws {
        let store = try matrix(classified: true)
        for duration in durations {
            for played in listens {
                let id = caseId(duration, played)
                let expected = PlayClassifier.classify(msPlayed: played, trackDurationMs: duration)
                let actual = try store.stats(jellyfinId: id)
                #expect(
                    actual.playCount == (expected.countsAsPlay ? 1 : 0),
                    "play: duration \(String(describing: duration)), played \(played)"
                )
                #expect(
                    actual.skipCount == (expected.skipped ? 1 : 0),
                    "skip: duration \(String(describing: duration)), played \(played)"
                )
            }
        }
    }

    /// A play and a skip are mutually exclusive, and the third outcome — neither — has
    /// to stay reachable. If the two predicates ever overlap, a library's play and skip
    /// counts would sum to more than the events that produced them.
    @Test("no listen is ever both a play and a skip, and the middle band survives")
    func outcomesAreDisjoint() throws {
        let store = try matrix(classified: true)
        var neither = 0
        for duration in durations {
            for played in listens {
                let stats = try store.stats(jellyfinId: caseId(duration, played))
                #expect(stats.playCount + stats.skipCount <= 1)
                if stats.playCount + stats.skipCount == 0 { neither += 1 }
            }
        }
        #expect(neither > 0, "the neither band collapsed; the two thresholds have met")
    }

    /// The specific disagreement that motivated all of this. A track played properly in
    /// March and skipped this morning was *last played* in March — and a rediscovery
    /// playlist and the track's detail sheet have to say so in the same breath.
    @Test("a skip does not move the last-played date, in either consumer")
    func aSkipDoesNotCountAsPlaying() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let day: Millis = 86_400_000
        try store.writeLocal { db in
            try TrackRef(
                jellyfinId: "t1", contentKey: "k1", title: "T",
                artist: "A", album: "A", durationMs: 200_000, lastSeenAt: now
            ).insert(db)
        }
        try store.recordPlay(
            jellyfinId: "t1", contentKey: "k1", startedAt: now - 200 * day,
            msPlayed: 200_000, trackDurationMs: 200_000
        )
        try store.recordPlay(
            jellyfinId: "t1", contentKey: "k1", startedAt: now - day,
            msPlayed: 3_000, trackDurationMs: 200_000
        )

        let stats = try store.stats(jellyfinId: "t1")
        #expect(stats.playCount == 1)
        #expect(stats.skipCount == 1)
        #expect(stats.lastPlayedAt == now - 200 * day)
        // The track was on yesterday, and that stays knowable — it is just not a play.
        #expect(stats.lastStartedAt == now - day)

        // The smart evaluator has to read the same date off the same events: yesterday's
        // skip must not rescue this track from "not played in the last 30 days".
        let notRecently = try SmartRules(
            rules: [SmartRule(field: .lastPlayed, op: .notInTheLast, value: .text("30d"))]
        )
        #expect(try store.evaluate(notRecently, asOf: now) == ["t1"])
    }
}
