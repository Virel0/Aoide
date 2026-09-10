import Foundation
import GRDB

// Recording and aggregating listening history. What a play *is* — and what a skip is
// — lives in `PlayDefinition.swift`, shared with the smart-playlist evaluator so the
// count printed beside a track and the membership of "played more than five times"
// cannot disagree.

// MARK: - Aggregate shapes

public struct TrackStats: Hashable, Sendable {
    public let jellyfinId: String
    public let playCount: Int
    public let skipCount: Int
    public let totalMsPlayed: Int64
    /// The first and last events that *qualified as plays* — the same figures the
    /// smart-playlist fields `first_played` and `last_played` read. A track skipped
    /// this morning and last genuinely listened to in March was last played in March,
    /// which is what a listener means by the phrase and what a "not played in six
    /// months" rule has to agree with.
    public let firstPlayedAt: Millis?
    public let lastPlayedAt: Millis?
    /// The last event of any kind, plays and skips and abandoned listens alike — when
    /// this track was last *on*, as opposed to last played. This is what "recently
    /// played" is ordered by; see `recentlyPlayed()`.
    public let lastStartedAt: Millis?

    public init(
        jellyfinId: String,
        playCount: Int,
        skipCount: Int,
        totalMsPlayed: Int64,
        firstPlayedAt: Millis?,
        lastPlayedAt: Millis?,
        lastStartedAt: Millis?
    ) {
        self.jellyfinId = jellyfinId
        self.playCount = playCount
        self.skipCount = skipCount
        self.totalMsPlayed = totalMsPlayed
        self.firstPlayedAt = firstPlayedAt
        self.lastPlayedAt = lastPlayedAt
        self.lastStartedAt = lastStartedAt
    }

    /// A track nothing is known about. Returned rather than `nil` so callers render
    /// "0 plays" instead of branching on absence — never played and never seen are
    /// the same thing to every screen that shows this.
    public static func empty(jellyfinId: String) -> TrackStats {
        TrackStats(
            jellyfinId: jellyfinId,
            playCount: 0,
            skipCount: 0,
            totalMsPlayed: 0,
            firstPlayedAt: nil,
            lastPlayedAt: nil,
            lastStartedAt: nil
        )
    }

    /// Whether this track has ever been *touched*, which is the question a "you have
    /// never heard this" empty state is asking. Keyed off `lastStartedAt`, not
    /// `lastPlayedAt`: a track skipped four times has a history, and reporting
    /// otherwise would offer to introduce the listener to something they keep
    /// rejecting.
    public var hasHistory: Bool { lastStartedAt != nil }
}

public typealias TrackPlays = (jellyfinId: String, playCount: Int)
public typealias ArtistPlays = (artist: String, playCount: Int)
/// Carries the artist because an album title is not a key: two records called
/// "Greatest Hits" are two records.
public typealias AlbumPlays = (album: String, artist: String, playCount: Int)
public typealias DayPlays = (day: String, playCount: Int)

/// A wrapped-style summary of one window of listening.
public struct Recap: Sendable {
    /// Half-open: `from` included, `to` excluded, so consecutive recaps neither
    /// double-count nor drop the event that lands exactly on the boundary.
    public let from: Millis
    public let to: Millis
    public let totalPlays: Int
    /// Every millisecond actually listened to in the window, including the fragments
    /// of tracks that were skipped. Time spent is time spent; counting only
    /// qualifying plays would report less listening than the listener did.
    public let totalMsPlayed: Int64
    public let distinctTracks: Int
    public let distinctArtists: Int
    public let distinctAlbums: Int
    public let topTracks: [TrackPlays]
    public let topArtists: [ArtistPlays]
    public let topAlbums: [AlbumPlays]
    public let busiestDay: DayPlays?
    /// Plays whose track is missing from the local cache, and which therefore appear
    /// in `totalPlays` but in none of the artist or album figures. Surfaced rather
    /// than swallowed so a recap can admit the gap instead of quietly disagreeing
    /// with itself.
    public let unattributedPlays: Int
}

// MARK: - Recording

public extension CurationStore {
    /// Opens a play. The event lands immediately with `msPlayed` 0; `finishPlay`
    /// fills in how it went.
    @discardableResult
    func beginPlay(
        jellyfinId: String,
        contentKey: String,
        source: PlaySource = .unknown,
        activity: Activity? = nil,
        at now: Millis = Date().millis
    ) throws -> PlayEvent {
        try append(PlayEvent(
            jellyfinId: jellyfinId,
            contentKey: contentKey,
            startedAt: now,
            msPlayed: 0,
            source: source,
            // Recorded from the moment the listen began. A session that ends
            // mid-track leaves that track tagged as what it was started during,
            // which is the honest answer and the one a later query wants.
            activity: activity,
            originDevice: deviceId
        ))
    }

    /// Finish counts split by what the listener was doing.
    ///
    /// The reason the tag exists: "the tracks I finish while gaming" is a
    /// question no music server can answer and this one can.
    func finishCounts(byActivity jellyfinIds: [String]) throws -> [Activity: FinishCounts] {
        guard !jellyfinIds.isEmpty else { return [:] }
        let rows: [(String, FinishCounts)] = try read { db in
            var found: [(String, FinishCounts)] = []
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                let fetched = try Row.fetchAll(db, sql: """
                    SELECT activity,
                           COUNT(*) AS starts,
                           SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END) AS completed
                    FROM playEvent
                    WHERE endedAt IS NOT NULL
                      AND (completed = 1 OR skipped = 1)
                      AND activity IS NOT NULL
                      AND jellyfinId IN (\(Self.placeholders(ids.count)))
                    GROUP BY activity
                    """, arguments: StatementArguments(ids))
                for row in fetched {
                    let raw: String? = row["activity"]
                    guard let raw else { continue }
                    found.append((raw, FinishCounts(starts: row["starts"], completed: row["completed"])))
                }
            }
            return found
        }
        var byActivity: [Activity: FinishCounts] = [:]
        for (raw, counts) in rows {
            // A word written by a newer build is dropped rather than guessed at.
            guard let activity = Activity.parse(raw) else { continue }
            byActivity[activity] = (byActivity[activity] ?? FinishCounts()) + counts
        }
        return byActivity
    }

    /// Closes a play, classifying it and amending the event `beginPlay` wrote.
    ///
    /// This is the one place that bends the append-only rule `playEvent` is
    /// documented with, so, the reasoning.
    ///
    /// The alternative — write nothing until the play ends — is simpler and honestly
    /// append-only, and it was rejected because of *how* plays end. iOS kills
    /// backgrounded audio apps, and it kills them during the long plays: the ones
    /// where the app sat in the background for an album's length. Recording only at
    /// the end loses exactly those, leaving a history biased towards short sessions
    /// — the same species of dishonesty this table exists to correct. An event
    /// written at the start survives it, and one that never got finished reads as
    /// "started, outcome unknown": `msPlayed` 0, neither `completed` nor `skipped`,
    /// so every aggregate below counts it as neither a play nor a skip.
    ///
    /// The op log stays single-valued because the amendment *replaces* the begin op
    /// instead of being written beside it — and replaces it under a **new** `opId`
    /// rather than rewriting the old payload in place. Rewriting in place is the
    /// trap: `opId` is the server's idempotency key, so an op accepted while its
    /// acknowledgement was lost is ignored on re-push, and the amended payload
    /// underneath that id would be discarded in silence. A new id is always applied.
    /// If the begin op had already synced, the server holds the 0 ms version and
    /// this correction lands after it in seq order — a full-row upsert, from the only
    /// device that ever writes this event id, so there is no per-field
    /// last-writer-wins for it to lose.
    @discardableResult
    func finishPlay(
        _ event: PlayEvent,
        msPlayed: Int,
        trackDurationMs: Int?,
        endedAt: Millis = Date().millis,
        completed: Bool? = nil
    ) throws -> PlayEvent {
        let outcome = PlayClassifier.classify(
            msPlayed: msPlayed,
            trackDurationMs: trackDurationMs,
            completed: completed
        )

        let amended: PlayEvent = {
            var row = event
            row.endedAt = endedAt
            // Clamped because a negative figure from a seek-before-start would poison
            // every SUM over this column, and there is no later point at which that
            // could be noticed.
            row.msPlayed = max(0, msPlayed)
            row.completed = outcome.completed
            row.skipped = outcome.skipped
            return row
        }()

        let op = Op(
            entity: PlayEvent.databaseTableName,
            entityId: amended.id,
            operation: .upsert,
            payload: try Self.json(amended),
            createdAt: endedAt
        )

        // `writeLocal` rather than `record` or `append`: `record` stamps
        // updatedAt/deleted/originDevice, which history rows do not carry, and
        // `append` can only insert. What the rule behind those two protects — the row
        // and its op in one transaction, never one without the other — is what this
        // block does explicitly.
        try writeLocal { db in
            // `save`, not `update`: if the row went missing under us the honest
            // outcome is a recorded play, not a play discarded over bookkeeping.
            try amended.save(db)
            _ = try Op
                .filter(Column("entity") == PlayEvent.databaseTableName)
                .filter(Column("entityId") == amended.id)
                .filter(Column("synced") == false)
                .deleteAll(db)
            try op.insert(db)
        }
        return amended
    }

    /// Records a play that is already over — an import, or a player that only reports
    /// once. Same two writes as `beginPlay` + `finishPlay`, minus the window in which
    /// a crash could leave the event open.
    @discardableResult
    func recordPlay(
        jellyfinId: String,
        contentKey: String,
        startedAt: Millis,
        msPlayed: Int,
        trackDurationMs: Int?,
        source: PlaySource = .unknown,
        completed: Bool? = nil
    ) throws -> PlayEvent {
        let outcome = PlayClassifier.classify(
            msPlayed: msPlayed,
            trackDurationMs: trackDurationMs,
            completed: completed
        )
        return try append(PlayEvent(
            jellyfinId: jellyfinId,
            contentKey: contentKey,
            startedAt: startedAt,
            endedAt: startedAt + Millis(max(0, msPlayed)),
            msPlayed: max(0, msPlayed),
            completed: outcome.completed,
            skipped: outcome.skipped,
            source: source,
            originDevice: deviceId
        ))
    }

}

// MARK: - Query shapes

/// The recurring pieces of this file's SQL.
///
/// The play and skip predicates themselves are *not* here — they live in
/// `PlayDefinition`, shared with the smart-playlist evaluator. Two copies of that rule
/// is the one duplication this package cannot afford.
enum HistorySQL {
    /// Every aggregate below reads the track cache through this one alias, so
    /// `PlayDefinition`'s fragments always have a `t` to take the duration from.
    static let eventsWithTrack = """
        FROM playEvent e LEFT JOIN track t ON t.jellyfinId = e.jellyfinId
        """

    /// Qualifies as a play, against `eventsWithTrack`'s aliases.
    static let qualifiesAsPlay = PlayDefinition.countsAsPlay(event: "e", track: "t")

    /// Qualifies as a skip, against the same aliases.
    ///
    /// Recomputed rather than read straight off `e.skipped`, for the reason spelled out
    /// on `PlayDefinition`: the flag is authoritative when it is set, but an event that
    /// the classifier never saw — imported history, or a row synced from an older build
    /// — carries `0` and still has to be judged on its numbers. Reading the column
    /// alone would report those as never skipped while the play count judged them
    /// properly, and the two figures sit next to each other on screen.
    static let qualifiesAsSkip = PlayDefinition.countsAsSkip(event: "e", track: "t")

    /// A single album, keyed. Concatenating with a printable separator would merge
    /// two real albums the moment one of them has that separator in its title; unit
    /// separator cannot appear in a tag.
    static let albumKey = "t.album || char(31) || COALESCE(t.albumArtist, t.artist)"

    /// SQLite caps host parameters per statement at 999 on the versions older iOS
    /// releases ship (raised to 32766 only in 3.32), and an id list here comes
    /// straight from a screenful of library rows. Chunking is not an optimisation; a
    /// 1,000-track album view would otherwise fail outright.
    static let maxParameters = 400
}

// MARK: - Aggregates

public extension CurationStore {
    /// Counts only events that qualify as plays — unlike Jellyfin's PlayCount, which
    /// counts anything that started.
    func playCount(jellyfinId: String) throws -> Int {
        try stats(jellyfinId: jellyfinId).playCount
    }

    /// Deliberately the batched query with one id, so a count shown on a row and the
    /// stats sheet behind it cannot disagree.
    func stats(jellyfinId: String) throws -> TrackStats {
        try stats(jellyfinIds: [jellyfinId])[jellyfinId] ?? .empty(jellyfinId: jellyfinId)
    }

    /// Stats for many tracks in one query.
    ///
    /// Every requested id comes back, zeroed if it has no history. That is what makes
    /// the per-row form unnecessary: a list view has no reason to fall back to
    /// `stats(jellyfinId:)` for its misses, which is how one query per row happens by
    /// accident.
    func stats(jellyfinIds: [String]) throws -> [String: TrackStats] {
        guard !jellyfinIds.isEmpty else { return [:] }
        return try read { db in
            var found: [String: TrackStats] = [:]
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                // `firstPlayedAt`/`lastPlayedAt` bracket the *qualifying plays* only, and
                // `lastStartedAt` brackets everything. They are separate columns because
                // they answer different questions that look identical until they
                // disagree: "when did you last play this" is a fact about listening,
                // "when was this last on" is a fact about the app. The smart-playlist
                // evaluator's `last_played` reads the same qualifying-plays-only figure,
                // so a rule for "not played in six months" and the date on the track's
                // detail sheet cannot contradict each other over a two-second skip.
                let sql = """
                    SELECT e.jellyfinId AS jellyfinId,
                           SUM(CASE WHEN \(HistorySQL.qualifiesAsPlay) THEN 1 ELSE 0 END) AS playCount,
                           SUM(CASE WHEN \(HistorySQL.qualifiesAsSkip) THEN 1 ELSE 0 END) AS skipCount,
                           COALESCE(SUM(e.msPlayed), 0) AS totalMsPlayed,
                           MIN(CASE WHEN \(HistorySQL.qualifiesAsPlay) THEN e.startedAt END) AS firstPlayedAt,
                           MAX(CASE WHEN \(HistorySQL.qualifiesAsPlay) THEN e.startedAt END) AS lastPlayedAt,
                           MAX(e.startedAt) AS lastStartedAt
                    \(HistorySQL.eventsWithTrack)
                    WHERE e.jellyfinId IN (\(Self.placeholders(ids.count)))
                    GROUP BY e.jellyfinId
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
                for row in rows {
                    let id: String = row["jellyfinId"]
                    let playCount: Int = row["playCount"]
                    let skipCount: Int = row["skipCount"]
                    let totalMsPlayed: Int64 = row["totalMsPlayed"]
                    let firstPlayedAt: Millis? = row["firstPlayedAt"]
                    let lastPlayedAt: Millis? = row["lastPlayedAt"]
                    let lastStartedAt: Millis? = row["lastStartedAt"]
                    found[id] = TrackStats(
                        jellyfinId: id,
                        playCount: playCount,
                        skipCount: skipCount,
                        totalMsPlayed: totalMsPlayed,
                        firstPlayedAt: firstPlayedAt,
                        lastPlayedAt: lastPlayedAt,
                        lastStartedAt: lastStartedAt
                    )
                }
            }
            var result: [String: TrackStats] = [:]
            for id in jellyfinIds { result[id] = found[id] ?? .empty(jellyfinId: id) }
            return result
        }
    }

    /// The share of decided outcomes that were skips, or `nil` when there is not
    /// enough evidence to say. The denominator counts plays and skips only: the
    /// "neither" band is neither, and folding it in would dilute a genuine skip
    /// habit into nothing.
    func skipRate(jellyfinId: String) throws -> Double? {
        let stats = try stats(jellyfinId: jellyfinId)
        let decided = stats.playCount + stats.skipCount
        guard decided >= PlayClassifier.minimumSkipSample else { return nil }
        return Double(stats.skipCount) / Double(decided)
    }

    func topTracks(since: Millis = 0, limit: Int = 10) throws -> [TrackPlays] {
        try read { db in try Self.topTracks(db, from: since, to: .max, limit: limit) }
    }

    func topArtists(since: Millis = 0, limit: Int = 10) throws -> [ArtistPlays] {
        try read { db in try Self.topArtists(db, from: since, to: .max, limit: limit) }
    }

    func topAlbums(since: Millis = 0, limit: Int = 10) throws -> [AlbumPlays] {
        try read { db in try Self.topAlbums(db, from: since, to: .max, limit: limit) }
    }

    /// Plays in the window whose track is not in the local cache, and which therefore
    /// cannot appear in `topArtists` or `topAlbums`.
    ///
    /// Those two inner-join the cache — an event with no cached row has no artist to
    /// be attributed to, and inventing an "Unknown Artist" bucket would put a
    /// placeholder in the middle of a recap. So they drop, and this exists so the
    /// drop can be stated out loud instead of leaving the totals quietly unequal.
    func unattributedPlays(since: Millis = 0, to: Millis = .max) throws -> Int {
        try read { db in try Self.unattributedPlays(db, from: since, to: to) }
    }

    /// Distinct tracks, most recently started first. Includes plays that were skipped
    /// or abandoned: "recently played" is a history of what was on, not a leaderboard.
    func recentlyPlayed(limit: Int = 50) throws -> [String] {
        try read { db in
            try String.fetchAll(db, sql: """
                SELECT e.jellyfinId
                FROM playEvent e
                GROUP BY e.jellyfinId
                ORDER BY MAX(e.startedAt) DESC
                LIMIT ?
                """, arguments: [limit])
        }
    }

    /// A wrapped-style summary of `[from, to)`.
    ///
    /// Every figure is fetched inside one read transaction, which is a single
    /// consistent snapshot in WAL mode — so a play landing mid-recap cannot make the
    /// headline total disagree with the lists underneath it.
    func recap(from: Millis, to: Millis) throws -> Recap {
        try read { db in
            let headline = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS totalPlays,
                       COUNT(DISTINCT e.jellyfinId) AS distinctTracks,
                       COUNT(DISTINCT t.artist) AS distinctArtists,
                       COUNT(DISTINCT \(HistorySQL.albumKey)) AS distinctAlbums
                \(HistorySQL.eventsWithTrack)
                WHERE e.startedAt >= ? AND e.startedAt < ? AND \(HistorySQL.qualifiesAsPlay)
                """, arguments: [from, to])

            let totalMsPlayed = try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(msPlayed), 0) FROM playEvent
                WHERE startedAt >= ? AND startedAt < ?
                """, arguments: [from, to]) ?? 0

            // Days are bucketed in the device's current time zone, not UTC: "the day
            // you listened most" is a human day. The cost is that generating the same
            // recap from another time zone can move an event across a boundary, which
            // is the right trade — a recap is read where it is generated.
            let busiest = try Row.fetchOne(db, sql: """
                SELECT strftime('%Y-%m-%d', e.startedAt / 1000, 'unixepoch', 'localtime') AS day,
                       COUNT(*) AS playCount
                \(HistorySQL.eventsWithTrack)
                WHERE e.startedAt >= ? AND e.startedAt < ? AND \(HistorySQL.qualifiesAsPlay)
                GROUP BY day
                ORDER BY playCount DESC, day
                LIMIT 1
                """, arguments: [from, to])

            var busiestDay: DayPlays?
            if let busiest {
                let day: String = busiest["day"]
                let playCount: Int = busiest["playCount"]
                busiestDay = (day: day, playCount: playCount)
            }

            let totalPlays: Int = headline?["totalPlays"] ?? 0
            let distinctTracks: Int = headline?["distinctTracks"] ?? 0
            let distinctArtists: Int = headline?["distinctArtists"] ?? 0
            let distinctAlbums: Int = headline?["distinctAlbums"] ?? 0

            return Recap(
                from: from,
                to: to,
                totalPlays: totalPlays,
                totalMsPlayed: totalMsPlayed,
                distinctTracks: distinctTracks,
                distinctArtists: distinctArtists,
                distinctAlbums: distinctAlbums,
                topTracks: try Self.topTracks(db, from: from, to: to, limit: 10),
                topArtists: try Self.topArtists(db, from: from, to: to, limit: 10),
                topAlbums: try Self.topAlbums(db, from: from, to: to, limit: 10),
                busiestDay: busiestDay,
                unattributedPlays: try Self.unattributedPlays(db, from: from, to: to)
            )
        }
    }

    // Ordering ties break on the name or id so a chart does not reshuffle between two
    // identical runs; SQLite's row order for equal keys is not promised, and a top-ten
    // that permutes on every refresh reads as a bug.

    private static func topTracks(_ db: Database, from: Millis, to: Millis, limit: Int) throws -> [TrackPlays] {
        try Row.fetchAll(db, sql: """
            SELECT e.jellyfinId AS jellyfinId, COUNT(*) AS playCount
            \(HistorySQL.eventsWithTrack)
            WHERE e.startedAt >= ? AND e.startedAt < ? AND \(HistorySQL.qualifiesAsPlay)
            GROUP BY e.jellyfinId
            ORDER BY playCount DESC, e.jellyfinId
            LIMIT ?
            """, arguments: [from, to, limit])
            .map { row in
                let id: String = row["jellyfinId"]
                let playCount: Int = row["playCount"]
                return (jellyfinId: id, playCount: playCount)
            }
    }

    /// Grouped on the track artist rather than the album artist: crediting every play
    /// on a compilation to "Various Artists" would be the single loudest entry in most
    /// recaps and would say nothing.
    private static func topArtists(_ db: Database, from: Millis, to: Millis, limit: Int) throws -> [ArtistPlays] {
        try Row.fetchAll(db, sql: """
            SELECT t.artist AS artist, COUNT(*) AS playCount
            FROM playEvent e JOIN track t ON t.jellyfinId = e.jellyfinId
            WHERE e.startedAt >= ? AND e.startedAt < ? AND \(HistorySQL.qualifiesAsPlay)
            GROUP BY t.artist
            ORDER BY playCount DESC, t.artist
            LIMIT ?
            """, arguments: [from, to, limit])
            .map { row in
                let artist: String = row["artist"]
                let playCount: Int = row["playCount"]
                return (artist: artist, playCount: playCount)
            }
    }

    private static func topAlbums(_ db: Database, from: Millis, to: Millis, limit: Int) throws -> [AlbumPlays] {
        try Row.fetchAll(db, sql: """
            SELECT t.album AS album,
                   COALESCE(t.albumArtist, t.artist) AS artist,
                   COUNT(*) AS playCount
            FROM playEvent e JOIN track t ON t.jellyfinId = e.jellyfinId
            WHERE e.startedAt >= ? AND e.startedAt < ? AND \(HistorySQL.qualifiesAsPlay)
            GROUP BY \(HistorySQL.albumKey)
            ORDER BY playCount DESC, t.album
            LIMIT ?
            """, arguments: [from, to, limit])
            .map { row in
                let album: String = row["album"]
                let artist: String = row["artist"]
                let playCount: Int = row["playCount"]
                return (album: album, artist: artist, playCount: playCount)
            }
    }

    private static func unattributedPlays(_ db: Database, from: Millis, to: Millis) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*)
            \(HistorySQL.eventsWithTrack)
            WHERE e.startedAt >= ? AND e.startedAt < ?
              AND t.jellyfinId IS NULL
              AND \(HistorySQL.qualifiesAsPlay)
            """, arguments: [from, to]) ?? 0
    }

    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }
}

// MARK: - Weighted shuffle

/// Turns history into a selection weight.
///
/// Three factors, multiplied, each with its own reason:
///
/// - **familiarity** `1 + 0.5·log₂(1 + plays)`. Logarithmic because linear play
///   counts do not shuffle: a track played 60 times would come up sixty times as
///   often as a new one, and the top twenty would crowd out the library. This makes
///   60 plays worth about 4× a never-played track — noticeably favoured, nowhere near
///   dominant.
/// - **skips** `1 − skips/(plays + skips + 2)`. The `+2` is a prior of one play and
///   one skip: without it a single skip of a single listen reads as total rejection,
///   which is the same mistake `skipRate` refuses to make by returning nil. With it,
///   one skip out of one is a third of the way down rather than all the way.
/// - **taste** ×1.75 liked, ×0.35 explicitly unliked, ×1 unrated. A like is a
///   deliberate statement and should outweigh a handful of plays; not liking
///   something yet is not a verdict.
///
/// The result is floored, never zeroed. A weight of zero means a track can never be
/// chosen again, and that does not present as a tuning decision — it presents as
/// "this song disappeared from my library", which is unreportable and unfindable.
/// The floor keeps the most-rejected track roughly two orders of magnitude behind a
/// favourite, which is rare enough to feel deliberate and frequent enough to come
/// back.
public enum PlayWeighting {
    public static let floor = 0.05
    public static let likedFactor = 1.75
    public static let unlikedFactor = 0.35
    /// Pseudo-counts: one imagined play and one imagined skip.
    public static let skipPrior = 2.0

    public static func weight(plays: Int, skips: Int, liked: Bool?) -> Double {
        let familiarity = 1 + 0.5 * log2(1 + Double(max(0, plays)))
        let skipRatio = Double(max(0, skips)) / (Double(max(0, plays) + max(0, skips)) + skipPrior)
        let taste = liked.map { $0 ? likedFactor : unlikedFactor } ?? 1
        return max(floor, familiarity * (1 - skipRatio) * taste)
    }
}

public extension CurationStore {
    /// A selection weight per track, for weighted random shuffle.
    ///
    /// Every requested id gets a weight, including ids with no history at all —
    /// a track missing from the returned dictionary is a track the shuffle can never
    /// pick, which is the same bug as a weight of zero wearing a different hat.
    func playWeights(jellyfinIds: [String]) throws -> [String: Double] {
        guard !jellyfinIds.isEmpty else { return [:] }
        let stats = try stats(jellyfinIds: jellyfinIds)

        let likes = try read { db -> [String: Bool] in
            var found: [String: Bool] = [:]
            for chunk in stride(from: 0, to: jellyfinIds.count, by: HistorySQL.maxParameters) {
                let ids = Array(jellyfinIds[chunk..<min(chunk + HistorySQL.maxParameters, jellyfinIds.count)])
                // The table has to be quoted: `like` is a SQL operator, and an
                // unquoted one here is a syntax error rather than a missing table.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT jellyfinId, liked FROM "like"
                    WHERE deleted = 0 AND jellyfinId IN (\(Self.placeholders(ids.count)))
                    """, arguments: StatementArguments(ids))
                for row in rows {
                    let id: String = row["jellyfinId"]
                    let liked: Bool = row["liked"]
                    found[id] = liked
                }
            }
            return found
        }

        var weights: [String: Double] = [:]
        for id in jellyfinIds {
            let stat = stats[id] ?? .empty(jellyfinId: id)
            weights[id] = PlayWeighting.weight(
                plays: stat.playCount,
                skips: stat.skipCount,
                liked: likes[id]
            )
        }
        return weights
    }
}
