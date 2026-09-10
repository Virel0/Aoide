import Foundation
import Testing
@testable import CurationKit

/// One candidate and the score both apps must give it.
private struct ParityCase: Sendable, CustomTestStringConvertible {
    let why: String
    let id: String
    let artist: String
    let genres: [String]
    let finish: FinishCounts?
    let score: Double

    var testDescription: String { why }
}

private let parityProfile = TasteProfile(
    genres: ["electronic": 0.5, "metal": 1],
    artists: ["perturbator": 0.4, "sabaton": 1],
    recent: ["heard-an-hour-ago"]
)

/// The same sixteen candidates the desktop scores, with the same sixteen scores
/// and the same one order.
///
/// "Both apps choose the same way" is a claim, and this table is the only thing
/// that makes it one: it is duplicated verbatim in the desktop's
/// `taste-ranking-parity.test.ts`, so either side changing a weight, the sample
/// floor it borrows from the finish rate, the lower-casing or the tie-break
/// breaks its own copy. The scores are exact numbers rather than an ordering on
/// purpose — two rankers that agree on today's library and disagree by a
/// hundredth are still two rankers, and they will part company on somebody
/// else's.
///
/// Rounded to six places, and both sides round: the arithmetic is IEEE doubles
/// in both languages and lands on the same bits, but a table full of
/// 0.15000000000000002 tells a reader nothing about the rule it is pinning.
private let parityTable: [ParityCase] = [
    ParityCase(
        why: "a favourite genre is most of what there is to earn",
        id: "metal-stranger",
        artist: "Nobody",
        genres: ["Metal"],
        finish: nil,
        score: 0.45
    ),
    ParityCase(
        why: "an unfamiliar genre earns nothing, and is not held against a track",
        id: "ambient-stranger",
        artist: "Nobody",
        genres: ["Ambient"],
        finish: nil,
        score: 0
    ),
    ParityCase(
        why: "a genre matches however it was capitalised",
        id: "shouted-genre",
        artist: "Nobody",
        genres: ["METAL"],
        finish: nil,
        score: 0.45
    ),
    ParityCase(
        why: "so does an artist",
        id: "shouted-artist",
        artist: "SABATON",
        genres: [],
        finish: nil,
        score: 0.3
    ),
    ParityCase(
        why: "four genres are not four times as relevant as the right one",
        id: "four-times-electronic",
        artist: "Nobody",
        genres: ["Electronic", "Electronic", "Electronic", "Electronic"],
        finish: nil,
        score: 0.225
    ),
    ParityCase(
        why: "the best match counts wherever in the tags it sits",
        id: "mixed-tags",
        artist: "Nobody",
        genres: ["Ambient", "Metal", "Electronic"],
        finish: nil,
        score: 0.45
    ),
    ParityCase(
        why: "the favourite artist, the favourite genre and always finished is the top of the scale",
        id: "favourite-everything",
        artist: "Sabaton",
        genres: ["Metal"],
        finish: FinishCounts(starts: 10, completed: 10),
        score: 1.05
    ),
    ParityCase(
        why: "a track you never finish sinks, but its genre still counts for it",
        id: "always-skipped",
        artist: "Nobody",
        genres: ["Metal"],
        finish: FinishCounts(starts: 10, completed: 0),
        score: 0.15
    ),
    ParityCase(
        why: "one skip out of one says nothing, and scores as no history at all",
        id: "barely-judged",
        artist: "Nobody",
        genres: ["Metal"],
        finish: FinishCounts(starts: 1, completed: 0),
        score: 0.45
    ),
    ParityCase(
        why: "two finishes out of two is still under the sample floor",
        id: "two-of-two",
        artist: "Nobody",
        genres: [],
        finish: FinishCounts(starts: 2, completed: 2),
        score: 0
    ),
    ParityCase(
        why: "three is the first sample either app will speak from",
        id: "three-of-three",
        artist: "Nobody",
        genres: [],
        finish: FinishCounts(starts: 3, completed: 3),
        score: 0.3
    ),
    ParityCase(
        why: "and it counts against a track exactly as far as it counts for one",
        id: "none-of-three",
        artist: "Nobody",
        genres: [],
        finish: FinishCounts(starts: 3, completed: 0),
        score: -0.3
    ),
    ParityCase(
        why: "two thirds finished is a third of the way up the band",
        id: "two-of-three",
        artist: "Nobody",
        genres: [],
        finish: FinishCounts(starts: 3, completed: 2),
        score: 0.1
    ),
    ParityCase(
        why: "a second-favourite genre and artist together still lose to a favourite genre alone",
        id: "second-favourite",
        artist: "Perturbator",
        genres: ["Electronic"],
        finish: nil,
        score: 0.345
    ),
    ParityCase(
        why: "the best song there is, heard an hour ago, falls below the worst that has not been",
        id: "heard-an-hour-ago",
        artist: "Sabaton",
        genres: ["Metal"],
        finish: FinishCounts(starts: 10, completed: 10),
        score: -0.35
    ),
    ParityCase(
        why: "nothing familiar and nothing measured is the middle of the scale",
        id: "nothing-known",
        artist: "Nobody",
        genres: [],
        finish: nil,
        score: 0
    ),
]

/// The one order the table's sixteen come out in, best first.
///
/// Four of them score exactly 0.45 and three exactly 0, so this pins the
/// tie-break as well as the scores: equal scores go in id order, which is what
/// makes the same library and the same history produce the same queue twice.
private let parityOrder = [
    "favourite-everything",
    "barely-judged",
    "metal-stranger",
    "mixed-tags",
    "shouted-genre",
    "second-favourite",
    "shouted-artist",
    "three-of-three",
    "four-times-electronic",
    "always-skipped",
    "two-of-three",
    "ambient-stranger",
    "nothing-known",
    "two-of-two",
    "none-of-three",
    "heard-an-hour-ago",
]

private let parityCandidates = parityTable.map {
    TasteCandidate(id: $0.id, artist: $0.artist, genres: $0.genres)
}

private let parityFinish: [String: FinishCounts] = parityTable.reduce(into: [:]) { counts, row in
    counts[row.id] = row.finish
}

/// Six places, the way the TypeScript copy rounds.
private func rounded(_ score: Double) -> Double {
    (score * 1_000_000).rounded() / 1_000_000
}

@Suite("Taste ranking parity")
struct TasteRankingParityTests {
    @Test("scores the desktop's table identically", arguments: parityTable)
    fileprivate func parityWithDesktop(_ row: ParityCase) {
        let candidate = TasteCandidate(id: row.id, artist: row.artist, genres: row.genres)
        #expect(rounded(TasteRanking.score(candidate, in: parityProfile, finish: row.finish)) == row.score)
    }

    @Test("puts the whole table in one order, ties broken on id")
    func oneOrder() {
        let ranked = TasteRanking.rank(
            parityCandidates,
            in: parityProfile,
            finish: parityFinish,
            limit: parityTable.count
        )
        #expect(ranked.map(\.id) == parityOrder)
    }

    @Test("takes the best five when five are asked for")
    func bestFive() {
        let ranked = TasteRanking.rank(
            parityCandidates,
            in: parityProfile,
            finish: parityFinish,
            limit: 5
        )
        #expect(ranked.map(\.id) == Array(parityOrder.prefix(5)))
    }

    @Test("asking for none gets none")
    func noneAsked() {
        #expect(TasteRanking.rank(parityCandidates, in: parityProfile, finish: parityFinish, limit: 0).isEmpty)
    }

    @Test("answers every case in the table")
    func everyCase() {
        #expect(parityTable.count == 16)
        #expect(parityOrder.count == parityTable.count)
    }
}
