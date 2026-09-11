import Foundation
import Testing
@testable import CurationKit

@Suite("Taste ranking")
struct TasteRankingTests {
    private let profile = TasteProfile(
        genres: ["metal": 1.0, "electronic": 0.5],
        artists: ["sabaton": 1.0, "perturbator": 0.4],
        recent: ["just-heard"]
    )

    private func candidate(_ id: String, artist: String = "Nobody", genres: [String] = []) -> TasteCandidate {
        TasteCandidate(id: id, artist: artist, genres: genres)
    }

    @Test("A favourite genre beats an unfamiliar one")
    func genreAffinity() {
        let familiar = candidate("a", genres: ["Metal"])
        let stranger = candidate("b", genres: ["Ambient"])
        #expect(TasteRanking.score(familiar, in: profile, finish: nil) > TasteRanking.score(stranger, in: profile, finish: nil))
    }

    @Test("Genres are matched however they are capitalised")
    func caseInsensitive() {
        #expect(TasteRanking.score(candidate("a", genres: ["METAL"]), in: profile, finish: nil) > 0)
        #expect(TasteRanking.score(candidate("a", artist: "SABATON"), in: profile, finish: nil) > 0)
    }

    @Test("Six genres are not six times as relevant as the right one")
    func bestGenreOnly() {
        let one = candidate("a", genres: ["Metal"])
        let many = candidate("b", genres: ["Electronic", "Electronic", "Electronic", "Electronic"])
        #expect(TasteRanking.score(one, in: profile, finish: nil) > TasteRanking.score(many, in: profile, finish: nil))
    }

    @Test("A familiar artist counts, but for less than the genre")
    func artistCountsForLess() {
        let rightGenre = candidate("a", artist: "Nobody", genres: ["Metal"])
        let rightArtist = candidate("b", artist: "Sabaton", genres: ["Ambient"])
        #expect(TasteRanking.score(rightGenre, in: profile, finish: nil) > TasteRanking.score(rightArtist, in: profile, finish: nil))
        #expect(TasteRanking.score(rightArtist, in: profile, finish: nil) > 0)
    }

    @Test("A track you always skip sinks below one you finish")
    func finishRateMoves() {
        let song = candidate("a", genres: ["Metal"])
        let finished = TasteRanking.score(song, in: profile, finish: FinishCounts(starts: 10, completed: 10))
        let neutral = TasteRanking.score(song, in: profile, finish: nil)
        let skipped = TasteRanking.score(song, in: profile, finish: FinishCounts(starts: 10, completed: 0))
        #expect(finished > neutral)
        #expect(neutral > skipped)
    }

    @Test("Too little history to judge is not held against a track")
    func sampleRuleApplies() {
        let song = candidate("a", genres: ["Metal"])
        // One skip out of one says nothing, and must score the same as no history.
        let barely = TasteRanking.score(song, in: profile, finish: FinishCounts(starts: 1, completed: 0))
        #expect(barely == TasteRanking.score(song, in: profile, finish: nil))
    }

    @Test("Something just heard does not come round again, however well it fits")
    func recentSinks() {
        // The best possible candidate, heard an hour ago, against the worst
        // possible one that has not been.
        let perfect = candidate("just-heard", artist: "Sabaton", genres: ["Metal"])
        let worst = candidate("new", genres: ["Ambient"])
        let perfectScore = TasteRanking.score(perfect, in: profile, finish: FinishCounts(starts: 10, completed: 10))
        let worstScore = TasteRanking.score(worst, in: profile, finish: FinishCounts(starts: 10, completed: 0))
        #expect(worstScore > perfectScore)
        #expect(TasteRanking.rank([perfect, worst], in: profile, limit: 1).map(\.id) == ["new"])
    }

    @Test("A record that can follow what is playing outranks one that cannot")
    func compatibilityCounts() {
        let a = candidate("a", genres: ["Metal"])
        let b = candidate("b", genres: ["Metal"])
        // Same taste; b can be mixed into what is playing and a cannot.
        let ranked = TasteRanking.rank([a, b], in: profile, compatibility: ["b": 0.9, "a": 0.1], limit: 2).map(\.id)
        #expect(ranked == ["b", "a"])
        // Worth more than a favourite artist: a record the room would love that
        // cannot follow what is playing is a record for later.
        let loved = candidate("loved", artist: "Sabaton", genres: ["Metal"])
        let follows = candidate("follows", genres: ["Metal"])
        let set = TasteRanking.rank([loved, follows], in: profile, compatibility: ["follows": 1.0, "loved": 0.2], limit: 2).map(\.id)
        #expect(set == ["follows", "loved"])
        // And nothing known about mixability changes nothing.
        let alone = TasteRanking.score(a, in: profile, finish: nil)
        #expect(TasteRanking.score(a, in: profile, finish: nil, compatibility: nil) == alone)
    }

    @Test("The same artist twice in a row is not a set")
    func sameArtistSinks() {
        let lately = TasteProfile(genres: ["metal": 1], artists: ["sabaton": 1], recent: [], recentArtists: ["sabaton"])
        let again = candidate("again", artist: "Sabaton", genres: ["Metal"])
        let someoneElse = candidate("else", artist: "Nobody", genres: ["Metal"])
        // The artist bonus alone would put Sabaton first; having just been
        // heard, they go second.
        #expect(TasteRanking.rank([again, someoneElse], in: lately, limit: 2).map(\.id) == ["else", "again"])
    }

    @Test("The same history twice gives the same order")
    func deterministic() {
        let candidates = [candidate("c"), candidate("a"), candidate("b")]
        let once = TasteRanking.rank(candidates, in: profile, limit: 3).map(\.id)
        let again = TasteRanking.rank(candidates.reversed(), in: profile, limit: 3).map(\.id)
        #expect(once == ["a", "b", "c"])
        #expect(once == again)
    }

    @Test("Asking for none gets none")
    func noLimit() {
        #expect(TasteRanking.rank([candidate("a")], in: profile, limit: 0).isEmpty)
    }
}

@Suite("Taste profile from history")
struct TasteProfileReadingTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func play(
        _ store: CurationStore,
        id: String,
        artist: String,
        genres: [String],
        completed: Bool,
        at: Millis
    ) throws {
        let ref = TrackRef(
            jellyfinId: id,
            contentKey: id,
            title: id,
            artist: artist,
            album: "Album",
            genres: genres,
            lastSeenAt: at
        )
        try store.writeLocal { db in try ref.save(db) }
        let event = try store.beginPlay(jellyfinId: id, contentKey: id, source: .album, at: at)
        _ = try store.finishPlay(
            event,
            msPlayed: completed ? 200_000 : 3_000,
            trackDurationMs: 200_000,
            endedAt: at + 1
        )
    }

    @Test("Favourites come out of what was finished")
    func favourites() throws {
        let store = try store()
        for i in 0..<6 {
            try play(store, id: "m\(i)", artist: "Sabaton", genres: ["Metal", "Power Metal"], completed: true, at: Millis(1_000 + i))
        }
        try play(store, id: "e1", artist: "Perturbator", genres: ["Electronic"], completed: true, at: 2_000)

        let profile = try store.tasteProfile()
        #expect(profile.genres["metal"] == 1.0)
        #expect(profile.genres["electronic"].map { $0 < 1.0 && $0 > 0 } == true)
        #expect(profile.artists["sabaton"] == 1.0)
    }

    @Test("A song skipped every time is not a favourite")
    func skippedIsNotAFavourite() throws {
        let store = try store()
        for i in 0..<6 {
            try play(store, id: "s\(i)", artist: "Skipped", genres: ["Skipped Genre"], completed: false, at: Millis(1_000 + i))
        }
        try play(store, id: "k1", artist: "Kept", genres: ["Kept Genre"], completed: true, at: 2_000)

        let profile = try store.tasteProfile()
        #expect(profile.genres["skipped genre"] == nil)
        #expect(profile.genres["kept genre"] == 1.0)
    }

    @Test("Whatever was played lately counts as heard, skipped or not")
    func recentIncludesSkips() throws {
        let store = try store()
        try play(store, id: "skipped", artist: "A", genres: ["G"], completed: false, at: 1_000)
        let profile = try store.tasteProfile()
        #expect(profile.recent.contains("skipped"))
        // And whose record it was, lower-cased like everything else here.
        #expect(profile.recentArtists.contains("a"))
    }

    @Test("Nothing listened to yet is a profile that says nothing")
    func emptyHistory() throws {
        let profile = try store().tasteProfile()
        #expect(profile.isEmpty)
        #expect(profile.recent.isEmpty)
    }
}
