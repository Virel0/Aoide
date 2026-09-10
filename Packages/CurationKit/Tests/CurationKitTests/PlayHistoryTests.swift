import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Play classification")
struct PlayClassificationTests {
    /// The boundary itself, from both sides. It is an exact millisecond rather than a
    /// float comparison precisely so a test can stand on it.
    @Test("exactly half a track is a play; a millisecond short is neither")
    func halfway() {
        let punk = 90_000

        let exactly = PlayClassifier.classify(msPlayed: 45_000, trackDurationMs: punk)
        #expect(exactly.countsAsPlay)
        #expect(!exactly.skipped)

        let justUnder = PlayClassifier.classify(msPlayed: 44_999, trackDurationMs: punk)
        #expect(!justUnder.countsAsPlay)
        // Well past a fifth, so it is not a rejection either — the honest answer is
        // that this listen was neither.
        #expect(!justUnder.skipped)
    }

    /// The reason the rule is a pair of numbers: one fixed threshold cannot serve both
    /// of these, and the same listener behaviour would score differently by genre.
    @Test("the fixed and fractional halves each cover what the other cannot")
    func bothEnds() {
        // A third of a 90-second punk song. A flat "30 seconds is a play" rule would
        // count it; half the track is the honest bar.
        let short = PlayClassifier.classify(msPlayed: 30_000, trackDurationMs: 90_000)
        #expect(!short.countsAsPlay)
        #expect(!short.skipped)

        // Five minutes of a twelve-minute track. Nobody sits through that by accident,
        // and a pure 50% rule would refuse to count it.
        let long = PlayClassifier.classify(msPlayed: 300_000, trackDurationMs: 720_000)
        #expect(long.countsAsPlay)
        #expect(!long.skipped)

        // Two minutes of the same track is under a fifth: a real skip.
        let bailed = PlayClassifier.classify(msPlayed: 120_000, trackDurationMs: 720_000)
        #expect(!bailed.countsAsPlay)
        #expect(bailed.skipped)
    }

    @Test("a four-second skip is a skip, which is the whole point")
    func fourSeconds() {
        let outcome = PlayClassifier.classify(msPlayed: 4_000, trackDurationMs: 180_000)
        #expect(!outcome.countsAsPlay)
        #expect(outcome.skipped)
    }

    @Test("a completed ten-second track is a play, however short")
    func shortButFinished() {
        let outcome = PlayClassifier.classify(msPlayed: 10_000, trackDurationMs: 10_000)
        #expect(outcome.completed)
        #expect(outcome.countsAsPlay)
        #expect(!outcome.skipped)
    }

    /// The player's last elapsed reading lands a beat short of the asset duration, so
    /// completion has to tolerate a shortfall or most full listens file as "neither".
    @Test("finishing a beat short of the duration still counts as finishing")
    func completionTolerance() {
        let inside = PlayClassifier.classify(
            msPlayed: 200_000 - PlayClassifier.completionToleranceMs,
            trackDurationMs: 200_000
        )
        #expect(inside.completed)

        let outside = PlayClassifier.classify(
            msPlayed: 200_000 - PlayClassifier.completionToleranceMs - 1,
            trackDurationMs: 200_000
        )
        #expect(!outside.completed)
        // Still a play: it is miles past half the track.
        #expect(outside.countsAsPlay)
    }

    /// The player knows things the numbers do not — a gapless crossfade ends a track
    /// for real while leaving elapsed time short.
    @Test("the player's word on completion overrides the arithmetic")
    func explicitCompletion() {
        let outcome = PlayClassifier.classify(msPlayed: 1_000, trackDurationMs: 300_000, completed: true)
        #expect(outcome.completed)
        #expect(outcome.countsAsPlay)
        #expect(!outcome.skipped)
    }

    @Test("with no duration, only the duration-free half of the rule applies")
    func unknownDuration() {
        #expect(PlayClassifier.classify(msPlayed: 240_000, trackDurationMs: nil).countsAsPlay)
        #expect(!PlayClassifier.classify(msPlayed: 239_999, trackDurationMs: nil).countsAsPlay)
        // Between 48 seconds and four minutes there is nothing to conclude.
        #expect(!PlayClassifier.classify(msPlayed: 239_999, trackDurationMs: nil).skipped)
        #expect(PlayClassifier.classify(msPlayed: 47_999, trackDurationMs: nil).skipped)
        // Nothing to have reached the end of, so completion cannot be inferred.
        #expect(!PlayClassifier.classify(msPlayed: 999_999, trackDurationMs: nil).completed)
    }

    /// Taken literally, a zero duration makes `msPlayed >= 0` a play, so every
    /// unparsed file would score a play for having been looked at.
    @Test("a zero duration is treated as no duration, not as an instantly-finished track")
    func zeroDuration() {
        let outcome = PlayClassifier.classify(msPlayed: 0, trackDurationMs: 0)
        #expect(!outcome.completed)
        #expect(!outcome.countsAsPlay)
        #expect(outcome.skipped)

        #expect(PlayClassifier.classify(msPlayed: 240_000, trackDurationMs: 0).countsAsPlay)
    }

    @Test("no listen is both a play and a skip")
    func mutuallyExclusive() {
        for duration in [nil, 0, 1, 10_000, 90_000, 240_000, 720_000] as [Int?] {
            for ms in [0, 1, 4_000, 47_999, 48_000, 120_000, 239_999, 240_000, 720_000] {
                let outcome = PlayClassifier.classify(msPlayed: ms, trackDurationMs: duration)
                #expect(!(outcome.countsAsPlay && outcome.skipped))
            }
        }
    }
}

@Suite("Play history")
struct PlayHistoryTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func cache(
        _ store: CurationStore,
        _ jellyfinId: String,
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String? = nil,
        durationMs: Int?
    ) throws {
        let track = TrackRef(
            jellyfinId: jellyfinId,
            contentKey: jellyfinId,
            title: jellyfinId,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            durationMs: durationMs,
            lastSeenAt: 0
        )
        try store.writeLocal { db in try track.insert(db) }
    }

    @discardableResult
    private func play(
        _ store: CurationStore,
        _ jellyfinId: String,
        at startedAt: Millis,
        msPlayed: Int,
        durationMs: Int?,
        completed: Bool? = nil
    ) throws -> PlayEvent {
        let event = try store.beginPlay(
            jellyfinId: jellyfinId,
            contentKey: jellyfinId,
            source: .album,
            at: startedAt
        )
        return try store.finishPlay(
            event,
            msPlayed: msPlayed,
            trackDurationMs: durationMs,
            endedAt: startedAt + Millis(msPlayed),
            completed: completed
        )
    }

    // MARK: - Recording

    /// The amendment must not leave two versions of the same event queued for the
    /// server; the finished one is the only one that should ever be pushed.
    @Test("finishing replaces the unsynced begin op rather than queueing a second")
    func finishReplacesPendingOp() throws {
        let store = try store()
        let event = try store.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 1_000)
        #expect(try store.pendingOps().count == 1)

        try store.finishPlay(event, msPlayed: 180_000, trackDurationMs: 200_000, endedAt: 181_000)

        let ops = try store.pendingOps()
        #expect(ops.count == 1)
        #expect(ops[0].entity == "playEvent")
        #expect(ops[0].entityId == event.id)
        #expect(ops[0].payload.contains("\"msPlayed\":180000"))

        let rows = try store.read { try PlayEvent.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].msPlayed == 180_000)
        #expect(rows[0].endedAt == 181_000)
    }

    /// A synced op cannot be replaced: the server has it, keyed by its opId, and
    /// re-pushing that id with a different payload would be ignored. The correction has
    /// to be a new op that lands after it.
    @Test("finishing after a sync appends a correction under a fresh op id")
    func finishAfterSync() throws {
        let store = try store()
        let event = try store.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 1_000)
        let beginOp = try #require(try store.pendingOps().first)
        try store.markSynced([beginOp.opId])

        try store.finishPlay(event, msPlayed: 180_000, trackDurationMs: 200_000, endedAt: 181_000)

        let pending = try store.pendingOps()
        #expect(pending.count == 1)
        #expect(pending[0].opId != beginOp.opId)
        #expect(pending[0].payload.contains("\"msPlayed\":180000"))

        // The acknowledged op is left exactly as the server saw it.
        let all = try store.read { try Op.fetchAll($0) }
        #expect(all.count == 2)
        #expect(all.contains { $0.opId == beginOp.opId && $0.synced })
    }

    /// The reason the event is written at the start at all: the app being killed
    /// mid-play is normal on iOS. What it must not do is invent an outcome.
    @Test("a play that never finished counts as neither a play nor a skip")
    func abandonedPlay() throws {
        let store = try store()
        try cache(store, "t1", durationMs: 200_000)
        try store.beginPlay(jellyfinId: "t1", contentKey: "k1", at: 1_000)

        let stats = try store.stats(jellyfinId: "t1")
        #expect(stats.playCount == 0)
        #expect(stats.skipCount == 0)
        // Nothing was played, so there is no last-played date to report — but the
        // track was on, and both facts have to survive independently. Collapsing them
        // into one column is what would let a killed listen read as a skip.
        #expect(stats.lastPlayedAt == nil)
        #expect(stats.lastStartedAt == 1_000)
        #expect(stats.hasHistory)
        // It was still on, so it belongs in "recently played".
        #expect(try store.recentlyPlayed() == ["t1"])
    }

    @Test("a one-shot record writes a classified event and its op")
    func oneShot() throws {
        let store = try store()
        try cache(store, "t1", durationMs: 200_000)
        try store.recordPlay(
            jellyfinId: "t1",
            contentKey: "k1",
            startedAt: 1_000,
            msPlayed: 5_000,
            trackDurationMs: 200_000
        )
        #expect(try store.stats(jellyfinId: "t1").skipCount == 1)
        #expect(try store.pendingOps().count == 1)
    }

    // MARK: - Aggregates

    @Test("play counts and skips add up across a mixed history")
    func mixedHistory() throws {
        let store = try store()
        try cache(store, "t1", durationMs: 200_000)

        for index in 0..<3 {
            try play(store, "t1", at: Millis(10_000 + index * 1_000), msPlayed: 200_000, durationMs: 200_000)
        }
        for index in 0..<2 {
            try play(store, "t1", at: Millis(20_000 + index * 1_000), msPlayed: 5_000, durationMs: 200_000)
        }
        // The middle band: a third of the track, counted as neither.
        try play(store, "t1", at: 30_000, msPlayed: 70_000, durationMs: 200_000)

        let stats = try store.stats(jellyfinId: "t1")
        #expect(stats.playCount == 3)
        #expect(stats.skipCount == 2)
        #expect(stats.totalMsPlayed == 3 * 200_000 + 2 * 5_000 + 70_000)
        // The play dates bracket the qualifying plays, which ended at 12,000 — the
        // skips at 20,000 and the half-listen at 30,000 are not plays and do not move
        // the date a listener would read as "last played". When the track was last
        // *on* is a separate figure, and it is the later one.
        #expect(stats.firstPlayedAt == 10_000)
        #expect(stats.lastPlayedAt == 12_000)
        #expect(stats.lastStartedAt == 30_000)
        #expect(try store.playCount(jellyfinId: "t1") == 3)
    }

    /// The SQL rebuilds the threshold from the cached duration, and it has to land on
    /// the same millisecond as the Swift classifier or a track's play count would
    /// depend on which one you asked.
    @Test("the SQL threshold agrees with the classifier to the millisecond")
    func sqlThresholdBoundary() throws {
        let store = try store()
        try cache(store, "on", durationMs: 200_000)
        try cache(store, "under", durationMs: 200_000)

        try play(store, "on", at: 1_000, msPlayed: 100_000, durationMs: 200_000)
        try play(store, "under", at: 1_000, msPlayed: 99_999, durationMs: 200_000)

        #expect(try store.playCount(jellyfinId: "on") == 1)
        #expect(try store.playCount(jellyfinId: "under") == 0)
    }

    /// If the cache holds a stale duration, the recomputed threshold can disagree with
    /// what the player saw. The stored skip flag wins, so nothing is counted twice.
    @Test("an event the player called a skip never also counts as a play")
    func staleCachedDuration() throws {
        let store = try store()
        // The cache thinks this is a one-minute track; it is really twelve.
        try cache(store, "t1", durationMs: 60_000)
        try play(store, "t1", at: 1_000, msPlayed: 50_000, durationMs: 720_000)

        let stats = try store.stats(jellyfinId: "t1")
        #expect(stats.skipCount == 1)
        #expect(stats.playCount == 0)
    }

    @Test("a play of an uncached track still counts, using the duration-free rule")
    func uncachedTrackCounts() throws {
        let store = try store()
        try play(store, "ghost", at: 1_000, msPlayed: 250_000, durationMs: nil)
        #expect(try store.playCount(jellyfinId: "ghost") == 1)
        #expect(try store.unattributedPlays() == 1)
        #expect(try store.topArtists().isEmpty)
    }

    @Test("the batched stats agree with the single-track form")
    func batchedMatchesSingle() throws {
        let store = try store()
        for id in ["t1", "t2", "t3"] { try cache(store, id, durationMs: 200_000) }
        try play(store, "t1", at: 1_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t1", at: 2_000, msPlayed: 5_000, durationMs: 200_000)
        try play(store, "t2", at: 3_000, msPlayed: 120_000, durationMs: 200_000)

        let batched = try store.stats(jellyfinIds: ["t1", "t2", "t3"])
        for id in ["t1", "t2", "t3"] {
            #expect(batched[id] == (try store.stats(jellyfinId: id)))
        }
        #expect(batched["t1"]?.playCount == 1)
        #expect(batched["t1"]?.skipCount == 1)
        #expect(batched["t2"]?.playCount == 1)
    }

    /// A list view that has to handle misses will handle them by asking again, one row
    /// at a time. Every requested id comes back so there is nothing to fall back to.
    @Test("every requested id comes back, zeroed when it has no history")
    func batchedFillsMisses() throws {
        let store = try store()
        let stats = try store.stats(jellyfinIds: ["a", "b", "c"])
        #expect(stats.count == 3)
        #expect(stats["b"] == TrackStats.empty(jellyfinId: "b"))
        #expect(stats["b"]?.hasHistory == false)
    }

    @Test("stats survive a batch larger than SQLite's parameter limit")
    func batchedChunking() throws {
        let store = try store()
        let ids = (0..<1_100).map { "t\($0)" }
        try cache(store, "t7", durationMs: 200_000)
        try play(store, "t7", at: 1_000, msPlayed: 200_000, durationMs: 200_000)

        let stats = try store.stats(jellyfinIds: ids)
        #expect(stats.count == ids.count)
        #expect(stats["t7"]?.playCount == 1)
        #expect(stats["t999"]?.playCount == 0)
    }

    @Test("top tracks rank by qualifying plays, and ties break deterministically")
    func topTracksRanking() throws {
        let store = try store()
        for id in ["a", "b", "c"] { try cache(store, id, durationMs: 200_000) }
        for index in 0..<3 { try play(store, "c", at: Millis(1_000 + index), msPlayed: 200_000, durationMs: 200_000) }
        try play(store, "a", at: 5_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "b", at: 6_000, msPlayed: 200_000, durationMs: 200_000)
        // Skips do not make a chart.
        for index in 0..<9 { try play(store, "b", at: Millis(7_000 + index), msPlayed: 2_000, durationMs: 200_000) }

        let top = try store.topTracks(limit: 3)
        #expect(top.map(\.jellyfinId) == ["c", "a", "b"])
        #expect(top.map(\.playCount) == [3, 1, 1])
        #expect(try store.topTracks(limit: 1).count == 1)
    }

    @Test("top artists and albums come from the track cache")
    func topArtistsAndAlbums() throws {
        let store = try store()
        try cache(store, "t1", artist: "Aphex Twin", album: "SAW", durationMs: 200_000)
        try cache(store, "t2", artist: "Aphex Twin", album: "SAW", durationMs: 200_000)
        try cache(store, "t3", artist: "Boards of Canada", album: "MHTRTC", durationMs: 200_000)

        try play(store, "t1", at: 1_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t2", at: 2_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t3", at: 3_000, msPlayed: 200_000, durationMs: 200_000)

        let artists = try store.topArtists()
        #expect(artists.map(\.artist) == ["Aphex Twin", "Boards of Canada"])
        #expect(artists.map(\.playCount) == [2, 1])

        let albums = try store.topAlbums()
        #expect(albums.map(\.album) == ["SAW", "MHTRTC"])
        #expect(albums.map(\.playCount) == [2, 1])
    }

    /// An album title is not a key. Two records called "Greatest Hits" are two records,
    /// and merging them would credit one artist with the other's listening.
    @Test("albums with the same title by different artists stay apart")
    func albumsAreKeyedByArtistToo() throws {
        let store = try store()
        try cache(store, "t1", artist: "One", album: "Greatest Hits", durationMs: 200_000)
        try cache(store, "t2", artist: "Two", album: "Greatest Hits", durationMs: 200_000)
        try play(store, "t1", at: 1_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t2", at: 2_000, msPlayed: 200_000, durationMs: 200_000)

        let albums = try store.topAlbums()
        #expect(albums.count == 2)
        #expect(Set(albums.map(\.artist)) == ["One", "Two"])
    }

    @Test("recently played is distinct and most recent first")
    func recentlyPlayed() throws {
        let store = try store()
        for id in ["a", "b"] { try cache(store, id, durationMs: 200_000) }
        try play(store, "a", at: 1_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "b", at: 2_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "a", at: 3_000, msPlayed: 200_000, durationMs: 200_000)

        #expect(try store.recentlyPlayed() == ["a", "b"])
        #expect(try store.recentlyPlayed(limit: 1) == ["a"])
    }

    /// One skip out of one play is not a 100% skip rate in any useful sense.
    @Test("skip rate stays silent until there is enough evidence")
    func skipRateSample() throws {
        let store = try store()
        try cache(store, "t1", durationMs: 200_000)
        for index in 0..<3 {
            try play(store, "t1", at: Millis(1_000 + index), msPlayed: 200_000, durationMs: 200_000)
        }
        try play(store, "t1", at: 4_000, msPlayed: 5_000, durationMs: 200_000)
        #expect(try store.skipRate(jellyfinId: "t1") == nil)

        try play(store, "t1", at: 5_000, msPlayed: 5_000, durationMs: 200_000)
        #expect(try store.skipRate(jellyfinId: "t1") == 0.4)
    }

    @Test("a track with no history has no skip rate rather than a rate of zero")
    func skipRateUnknown() throws {
        let store = try store()
        #expect(try store.skipRate(jellyfinId: "nothing") == nil)
    }

    // MARK: - Recap

    @Test("a recap totals the window and names the busiest day")
    func recap() throws {
        let store = try store()
        // Midday UTC on two consecutive days: whatever the machine's time zone, both
        // shift by the same offset and stay in distinct local days, so the grouping
        // holds without the test asserting a particular date string.
        let dayOne: Millis = 1_699_963_200_000
        let dayTwo = dayOne + 86_400_000

        try cache(store, "t1", artist: "Aphex Twin", album: "SAW", durationMs: 200_000)
        try cache(store, "t2", artist: "Boards of Canada", album: "MHTRTC", durationMs: 200_000)

        for index in 0..<3 {
            try play(store, "t1", at: dayOne + Millis(index) * 3_600_000, msPlayed: 200_000, durationMs: 200_000)
        }
        try play(store, "t2", at: dayOne + 4 * 3_600_000, msPlayed: 5_000, durationMs: 200_000)
        try play(store, "t2", at: dayTwo, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t9", at: dayTwo + 3_600_000, msPlayed: 250_000, durationMs: nil)

        let recap = try store.recap(from: dayOne, to: dayOne + 3 * 86_400_000)
        #expect(recap.totalPlays == 5)
        #expect(recap.totalMsPlayed == Int64(3 * 200_000 + 5_000 + 200_000 + 250_000))
        #expect(recap.distinctTracks == 3)
        // The uncached track has no artist to be counted as.
        #expect(recap.distinctArtists == 2)
        #expect(recap.distinctAlbums == 2)
        #expect(recap.unattributedPlays == 1)
        #expect(recap.topTracks.map(\.jellyfinId) == ["t1", "t2", "t9"])
        #expect(recap.topArtists.first?.artist == "Aphex Twin")
        #expect(recap.topAlbums.first?.album == "SAW")
        #expect(recap.busiestDay?.playCount == 3)
    }

    /// Half-open, so two consecutive recaps neither double-count the event on the
    /// boundary nor drop it.
    @Test("the recap window includes its start and excludes its end")
    func recapWindow() throws {
        let store = try store()
        try cache(store, "t1", durationMs: 200_000)
        try play(store, "t1", at: 1_000, msPlayed: 200_000, durationMs: 200_000)
        try play(store, "t1", at: 2_000, msPlayed: 200_000, durationMs: 200_000)

        #expect(try store.recap(from: 1_000, to: 2_000).totalPlays == 1)
        #expect(try store.recap(from: 2_000, to: 3_000).totalPlays == 1)
        #expect(try store.recap(from: 0, to: 1_000).totalPlays == 0)
    }

    @Test("an empty recap is zeros rather than a failure")
    func emptyRecap() throws {
        let store = try store()
        let recap = try store.recap(from: 0, to: 1_000)
        #expect(recap.totalPlays == 0)
        #expect(recap.totalMsPlayed == 0)
        #expect(recap.busiestDay == nil)
        #expect(recap.topTracks.isEmpty)
    }

    // MARK: - Weighted shuffle

    /// A weight of zero does not present as a tuning decision. It presents as "this
    /// song disappeared from my library".
    @Test("no track is ever weighted to zero, however badly it scores")
    func weightsAreNeverZero() throws {
        #expect(PlayWeighting.weight(plays: 0, skips: 1_000, liked: false) == PlayWeighting.floor)
        #expect(PlayWeighting.weight(plays: 0, skips: 0, liked: false) > 0)
        #expect(PlayWeighting.weight(plays: 0, skips: 0, liked: nil) > 0)
    }

    /// The same reasoning as `skipRate`'s minimum sample, applied continuously: a
    /// single skip is not a verdict.
    @Test("one skip out of one listen only nudges the weight")
    func singleSkipIsNotRejection() throws {
        let neutral = PlayWeighting.weight(plays: 0, skips: 0, liked: nil)
        let onceSkipped = PlayWeighting.weight(plays: 0, skips: 1, liked: nil)
        #expect(onceSkipped < neutral)
        #expect(onceSkipped > neutral * 0.6)
    }

    /// Logarithmic, so the twenty tracks played most do not crowd out the library.
    @Test("plays raise the weight with diminishing returns")
    func familiarityFlattens() throws {
        let none = PlayWeighting.weight(plays: 0, skips: 0, liked: nil)
        let some = PlayWeighting.weight(plays: 10, skips: 0, liked: nil)
        let many = PlayWeighting.weight(plays: 100, skips: 0, liked: nil)
        #expect(some > none)
        #expect(many > some)
        #expect(many < none * 10)
    }

    @Test("weights read likes, plays and skips out of the store")
    func playWeights() throws {
        let store = try store()
        for id in ["loved", "neutral", "skipped", "disliked"] { try cache(store, id, durationMs: 200_000) }

        for index in 0..<5 {
            try play(store, "loved", at: Millis(1_000 + index), msPlayed: 200_000, durationMs: 200_000)
            try play(store, "neutral", at: Millis(2_000 + index), msPlayed: 200_000, durationMs: 200_000)
            try play(store, "skipped", at: Millis(3_000 + index), msPlayed: 2_000, durationMs: 200_000)
        }
        try store.record(Like(jellyfinId: "loved", contentKey: "loved", liked: true, updatedAt: 0, originDevice: ""))
        try store.record(Like(jellyfinId: "disliked", contentKey: "disliked", liked: false, updatedAt: 0, originDevice: ""))

        let weights = try store.playWeights(jellyfinIds: ["loved", "neutral", "skipped", "disliked", "unheard"])
        #expect(weights.count == 5)
        // An id with no history at all still gets a weight; a missing key is a track
        // the shuffle can never pick.
        let unheard = try #require(weights["unheard"])
        #expect(unheard > 0)

        let loved = try #require(weights["loved"])
        let neutral = try #require(weights["neutral"])
        let skipped = try #require(weights["skipped"])
        let disliked = try #require(weights["disliked"])
        #expect(loved > neutral)
        #expect(skipped < neutral)
        #expect(disliked < unheard)
        #expect(skipped > 0)
        #expect(disliked > 0)
    }

    @Test("an unliked row that was undone stops counting against a track")
    func softDeletedLikeIgnored() throws {
        let store = try store()
        let like = try store.record(
            Like(jellyfinId: "t1", contentKey: "t1", liked: false, updatedAt: 0, originDevice: "")
        )
        let penalised = try #require(try store.playWeights(jellyfinIds: ["t1"])["t1"])

        try store.record(like, deleted: true)
        let restored = try #require(try store.playWeights(jellyfinIds: ["t1"])["t1"])
        #expect(restored > penalised)
    }
}

/// Mirrored by the desktop's `finish-rate.test.ts`. The two must not drift, or
/// one library reports two figures.
@Suite("Finish rate")
struct FinishRateTests {
    @Test("too little history says nothing at all")
    func floor() {
        #expect(FinishRate.rate(FinishCounts(starts: 2, completed: 2)) == nil)
        #expect(FinishRate.rate(FinishCounts(starts: 0, completed: 0)) == nil)
        #expect(FinishRate.rate(FinishCounts(starts: 3, completed: 3)) == 1)
    }

    @Test("a set sums its counts rather than averaging its rates")
    func aggregation() {
        // Heard fifty times and never finished, against one heard three times
        // and always finished. The mean of the rates would say 50%; the album
        // says what actually happened.
        let heavy = FinishCounts(starts: 50, completed: 0)
        let light = FinishCounts(starts: 3, completed: 3)
        let combined = try! #require(FinishRate.rate(over: [heavy, light]))
        #expect(abs(combined - 3.0 / 53.0) < 0.0001)

        let meanOfRates = ((FinishRate.rate(heavy) ?? 0) + (FinishRate.rate(light) ?? 0)) / 2
        #expect(abs(combined - meanOfRates) > 0.4, "must not be the mean of the rates")
    }

    @Test("counted from the store: only decided listens, every id present")
    func fromStore() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        // Three decided listens, two of them finished.
        for (completed, skipped) in [(true, false), (true, false), (false, true)] {
            let event = try store.beginPlay(jellyfinId: "t1", contentKey: "k1")
            _ = try store.finishPlay(
                event,
                msPlayed: completed ? 200_000 : 3_000,
                trackDurationMs: 200_000,
                endedAt: Date().millis
            )
            _ = (completed, skipped)
        }
        // One still open: no verdict, so it counts for nothing.
        _ = try store.beginPlay(jellyfinId: "t1", contentKey: "k1")

        let counts = try store.finishCounts(jellyfinIds: ["t1", "never-played"])
        #expect(counts["never-played"] == FinishCounts(starts: 0, completed: 0))
        let t1 = try #require(counts["t1"])
        #expect(t1.starts == 3, "the open listen must not count")
        #expect(t1.completed == 2)
        #expect(FinishRate.percentDescription(t1) == "67%")
    }

    @Test("nothing asked for, nothing returned")
    func empty() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        #expect(try store.finishCounts(jellyfinIds: []).isEmpty)
        #expect(try store.finishRate(jellyfinIds: []) == nil)
    }
}
