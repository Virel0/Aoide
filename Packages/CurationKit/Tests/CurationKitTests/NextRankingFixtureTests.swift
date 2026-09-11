import Foundation
import Testing
@testable import CurationKit

/// The `/aoide/next` parity fixture — `docs/infinity.md` §5.
///
/// `Fixtures/next-ranking-fixture.json` holds a hand-written library, a
/// history, a flag, and four requests with every score and factor the rule
/// gives for each. The sidecar and the desktop read the same file. This
/// suite runs `NextRanking` over it and compares to six decimals.
///
/// To regenerate `expected` after a deliberate change to the rule, run with
/// `AOIDE_WRITE_NEXT_FIXTURE=1` and copy the printed path's contents over the
/// fixture in all three repos — never one.
@Suite("What plays next, held to the fixture")
struct NextRankingFixtureTests {
    struct Fixture: Codable {
        struct Record: Codable {
            var id: String
            var artist: String
            var genres: [String]
            var bpm: Double?
            var bpmStability: Double?
            var key: String?
            var sections: [Section]?
        }

        struct Section: Codable {
            var startMs: Double
            var endMs: Double
            var energy: Double
        }

        struct Play: Codable {
            var id: String
            var startedAt: Int64
            var completed: Bool
            var skipped: Bool
        }

        struct Case: Codable {
            var name: String
            var seed: String
            var queue: [String]
            var recent: [String]
            var mode: NextChooser.Mode
            var limit: Int
            var expected: Expected?
        }

        struct Expected: Codable {
            var events: Int
            var candidates: [Candidate]
        }

        struct Candidate: Codable {
            var id: String
            var score: Double
            var factors: NextChooser.Factors
        }

        var about: String
        var now: Int64
        var tasteWindowDays: Int
        var library: [Record]
        var plays: [Play]
        var notInterested: [String]
        /// The planner's pair scores, keyed "from>to"; a pair not listed is unread.
        var mixability: [String: Double]?
        var cases: [Case]
    }

    static func mixability(of fixture: Fixture) -> NextRanking.Mixability {
        let table = fixture.mixability ?? [:]
        return { from, to in table["\(from)>\(to)"] }
    }

    static let url = Bundle.module.url(forResource: "next-ranking-fixture", withExtension: "json", subdirectory: "Fixtures")!

    static func load() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    static func library(from fixture: Fixture) -> NextRanking.Library {
        NextRanking.Library(
            records: fixture.library.map {
                NextRanking.Record(
                    id: $0.id, artist: $0.artist, genres: $0.genres,
                    bpm: $0.bpm, bpmStability: $0.bpmStability, key: $0.key,
                    sections: $0.sections?.map { NextRanking.Section(startMs: $0.startMs, endMs: $0.endMs, energy: $0.energy) }
                )
            },
            plays: fixture.plays.map { NextRanking.Play(id: $0.id, startedAt: $0.startedAt, completed: $0.completed, skipped: $0.skipped) },
            notInterested: Set(fixture.notInterested),
            now: fixture.now
        )
    }

    static func round6(_ value: Double) -> Double { (value * 1_000_000).rounded() / 1_000_000 }

    @Test("Every case in the fixture scores exactly as written")
    func matchesFixture() throws {
        var fixture = try Self.load()
        let library = Self.library(from: fixture)
        #expect(fixture.tasteWindowDays == 90)

        let writing = ProcessInfo.processInfo.environment["AOIDE_WRITE_NEXT_FIXTURE"] == "1"

        for index in fixture.cases.indices {
            let testCase = fixture.cases[index]
            let query = NextRanking.Query(
                seed: testCase.seed, queue: testCase.queue, recent: testCase.recent,
                mode: testCase.mode, limit: testCase.limit
            )
            let (results, events) = NextRanking.rank(query, in: library, mixability: Self.mixability(of: fixture))
            let actual = Fixture.Expected(
                events: events,
                candidates: results.map {
                    Fixture.Candidate(
                        id: $0.id,
                        score: Self.round6($0.score),
                        factors: NextChooser.Factors(
                            taste: Self.round6($0.factors.taste),
                            kinship: $0.factors.kinship.map(Self.round6),
                            freshness: Self.round6($0.factors.freshness),
                            similarity: Self.round6($0.factors.similarity),
                            mixability: $0.factors.mixability.map(Self.round6),
                            arc: Self.round6($0.factors.arc)
                        )
                    )
                }
            )

            if writing {
                fixture.cases[index].expected = actual
                continue
            }

            let expected = try #require(testCase.expected, "\(testCase.name): no expected block — generate one")
            #expect(actual.events == expected.events, "\(testCase.name): events")
            #expect(actual.candidates.map(\.id) == expected.candidates.map(\.id), "\(testCase.name): order")
            for (got, want) in zip(actual.candidates, expected.candidates) where got.id == want.id {
                #expect(abs(got.score - want.score) <= 1e-6, "\(testCase.name) \(got.id): score \(got.score) vs \(want.score)")
                #expect(abs(got.factors.taste - want.factors.taste) <= 1e-6, "\(testCase.name) \(got.id): taste")
                #expect(got.factors.kinship == want.factors.kinship, "\(testCase.name) \(got.id): kinship")
                #expect(got.factors.freshness == want.factors.freshness, "\(testCase.name) \(got.id): freshness")
                #expect(abs(got.factors.similarity - want.factors.similarity) <= 1e-6, "\(testCase.name) \(got.id): similarity")
                #expect(got.factors.mixability == want.factors.mixability, "\(testCase.name) \(got.id): mixability")
                #expect(abs(got.factors.arc - want.factors.arc) <= 1e-6, "\(testCase.name) \(got.id): arc")
            }
        }

        if writing {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("next-ranking-fixture.json")
            try encoder.encode(fixture).write(to: out)
            print("Wrote \(out.path)")
        }
    }

    // The rows below are the fixture's arithmetic done by hand, so the file
    // is not only "what the code said": a reader can check each against the
    // contract in docs/infinity.md without running anything.

    @Test("Hand-checked: t17 after t01 with an empty queue")
    func handCheckedTop() throws {
        let fixture = try Self.load()
        let library = Self.library(from: fixture)
        let query = NextRanking.Query(seed: "t01", queue: [], recent: ["t02", "t12"], mode: .infinity, limit: 20)
        let (results, events) = NextRanking.rank(query, in: library)
        // Eleven finished plays inside ninety days; the twelfth is 91 days old.
        #expect(events == 11)

        let t17 = try #require(results.first { $0.id == "t17" })
        // Taste: house is the strongest genre (5 of the finished plays) → 1;
        // Solenne the strongest artist (5) → 1; t17 has one decided listen,
        // below the sample of three → no bias. 0.45 + 0.3 = 0.75.
        #expect(abs(t17.factors.taste - 0.75) <= 1e-9)
        // Kinship: no genre shared (house vs synthwave/electronic) → 0.
        #expect(t17.factors.kinship == 0)
        // Similarity: 125/120 = 1.041667, bend 4.17% → 1 − (0.041667 − 0.02)/0.04
        // = 0.458333; 8A/8A → 1; energy |0.6 − 0.78| → 0.82. Mean of three.
        #expect(abs(t17.factors.similarity - (0.4583333333 + 1 + 0.82) / 3) <= 1e-6)
        // Arc: recent reversed [t12 0.6, t02 0.65] + seed 0.6 → not a rise, not
        // a fall; target = 0.6; 1 − |0.78 − 0.6| = 0.82.
        #expect(abs(t17.factors.arc - 0.82) <= 1e-9)
        // t17 was finished 400 hours ago: among the last 40 started → heard
        // lately, and its artist too. Both penalties.
        #expect(t17.factors.freshness == 0)
        #expect(abs(t17.score - (0.75 + 0 * 0.6 + (0.4583333333 + 1 + 0.82) / 3 * 0.4 + 0.82 * 0.2 - 1.4 - 0.4)) <= 1e-6)
    }

    @Test("Hand-checked: t16, a twin of the seed by an artist heard lately")
    func handCheckedTwin() throws {
        let fixture = try Self.load()
        let library = Self.library(from: fixture)
        let query = NextRanking.Query(seed: "t01", queue: [], recent: ["t02", "t12"], mode: .infinity, limit: 20)
        let (results, _) = NextRanking.rank(query, in: library)

        let t16 = try #require(results.first { $0.id == "t16" })
        // Synthwave 1 of 5 → 0.2, electronic 2 of 5 → 0.4, best 0.4 → 0.18;
        // Marrow 1 of 5 → 0.2 → 0.06; never played → no bias. 0.24.
        #expect(abs(t16.factors.taste - 0.24) <= 1e-9)
        // First genre the seed's → kin 1; same tempo 1; same key 1; energy 1 − 0 = 1.
        #expect(t16.factors.kinship == 1)
        // t13 is pop first and synthwave second: a secondary tag shared with
        // the seed is worth half. t20 is pop only: nothing shared.
        let t13 = try #require(results.first { $0.id == "t13" })
        #expect(t13.factors.kinship == 0.5)
        let t20 = try #require(results.first { $0.id == "t20" })
        #expect(t20.factors.kinship == 0)
        #expect(abs(t16.factors.similarity - 1) <= 1e-9)
        // Never played, but Marrow is the artist of t02, heard on this device.
        #expect(t16.factors.freshness == 0.5)
        #expect(abs(t16.score - (0.24 + 0.6 + 0.4 + 1.0 * 0.2 - 0.4)) <= 1e-9)
    }

    @Test("Hand-checked: the rising set asks for a breather, and Auto DJ writes a null")
    func handCheckedArc() throws {
        let fixture = try Self.load()
        let library = Self.library(from: fixture)
        let query = NextRanking.Query(seed: "t01", queue: ["t03", "t07", "t08"], recent: ["t02", "t12"], mode: .autodj, limit: 20)
        // The chain starts from t08, the end of the queue, and no pair from
        // t08 is in the table: the first record is the best-chosen one, with
        // a null mixability.
        let (results, _) = NextRanking.rank(query, in: library, mixability: Self.mixability(of: fixture))
        #expect(results.first?.factors.mixability == nil)

        // The last four: t01 0.6, t03 0.8, t07 0.85, t08 0.9 — rose three
        // times; target 0.9 − 0.25 = 0.65. t15 is at 0.65 exactly.
        let t15 = try #require(results.first { $0.id == "t15" })
        #expect(abs(t15.factors.arc - 1) <= 1e-9)
        // The queued records are never returned.
        #expect(!results.contains { ["t03", "t07", "t08"].contains($0.id) })
        // Deep Harbour is the artist of the last three queued: t18 pays.
        let t18 = try #require(results.first { $0.id == "t18" })
        #expect(t18.factors.freshness == 0.5)
    }

    @Test("Hand-checked: chosen by taste and kin, then ordered as a chain")
    func handCheckedOrder() throws {
        let fixture = try Self.load()
        let library = Self.library(from: fixture)
        let query = NextRanking.Query(seed: "t01", queue: [], recent: ["t02", "t12"], mode: .autodj, limit: 5)
        let (results, _) = NextRanking.rank(query, in: library, mixability: Self.mixability(of: fixture))
        // The five best by the choosing score, in that order, are t16, t20,
        // t14, t11, t15 (see the infinity case with the same request). Not
        // one of them was chosen for mixing with the seed: mixability is not
        // in the choosing score, and the reported scores are the choosing
        // scores in the choosing order's own figures.
        let chosen = Set(results.map(\.id))
        #expect(chosen == ["t16", "t20", "t14", "t11", "t15"])
        // Ordered from the seed: t01→t16 is 0.9 (best); t16→t20 0.85;
        // t20→t14 0.8; t14→t15 0.9 beats t14→t11 0.6; t15→t11 0.5 last.
        #expect(results.map(\.id) == ["t16", "t20", "t14", "t15", "t11"])
        #expect(results.map(\.factors.mixability) == [0.9, 0.85, 0.8, 0.9, 0.5])
        // A record with no pair in the table would be a crossfade, 0.15, and
        // would lose to any read pair — pinned by t11 going last here even
        // though its choosing score is above t15's.
        let t11 = try #require(results.first { $0.id == "t11" })
        let t15 = try #require(results.first { $0.id == "t15" })
        #expect(t11.score > t15.score)
    }

    @Test("Hand-checked: the falling set, from a seed nothing can be measured against")
    func handCheckedFall() throws {
        let fixture = try Self.load()
        let library = Self.library(from: fixture)
        let query = NextRanking.Query(seed: "t10", queue: [], recent: ["t03", "t07"], mode: .infinity, limit: 20)
        let (results, _) = NextRanking.rank(query, in: library)

        // recent reversed [t07 0.85, t03 0.8] + seed 0.1: fell twice; target 0.3.
        let t05 = try #require(results.first { $0.id == "t05" })
        #expect(abs(t05.factors.arc - (1 - abs(0.4 - 0.3))) <= 1e-9)
        // The seed has no tempo and no key: tempo left out, key 0.5, energy
        // 1 − |0.1 − 0.4| = 0.7. Mean of two. No kin: ambient vs indie/pop.
        #expect(abs(t05.factors.similarity - (0.5 + 0.7) / 2) <= 1e-6)
        #expect(t05.factors.kinship == 0)
        // t11 shares ambient but has no arrangement: kin 1; key 0.5 is the
        // one similarity part → 0.5; arc 0.5 for a record with nothing to read.
        let t11 = try #require(results.first { $0.id == "t11" })
        #expect(t11.factors.kinship == 1)
        #expect(abs(t11.factors.similarity - 0.5) <= 1e-9)
        #expect(abs(t11.factors.arc - 0.5) <= 1e-9)
        // The flagged record never appears, whatever it would have scored.
        #expect(!results.contains { $0.id == "t19" })
    }
}
