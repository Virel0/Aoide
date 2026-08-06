import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Smart playlists")
struct SmartPlaylistTests {

    /// A fixed instant, so every relative-date expectation is arithmetic rather than
    /// a race with the wall clock.
    private let now: Millis = 1_700_000_000_000
    private let day: Millis = 86_400_000

    /// Month and year arithmetic depends on a time zone, so the tests pin one. With
    /// `Calendar.current` these would pass in London and fail in Auckland.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Fixture

    /// Four tracks whose histories cover the shapes that matter: played often and
    /// recently, played once long ago and skipped since, skipped only, and never
    /// touched at all.
    private func library() throws -> CurationStore {
        let store = try CurationStore.inMemory(deviceId: "phone")

        try seed(store, TrackRef(
            jellyfinId: "so-what", contentKey: "k1", title: "So What",
            artist: "Miles Davis", album: "Kind of Blue", albumArtist: "Miles Davis",
            durationMs: 545_000, year: 1959, genres: ["Jazz", "Modal"], lastSeenAt: now
        ))
        try seed(store, TrackRef(
            jellyfinId: "paranoid", contentKey: "k2", title: "Paranoid Android",
            artist: "Radiohead", album: "OK Computer", albumArtist: "Radiohead",
            durationMs: 383_000, year: 1997, genres: ["Alternative Rock"], lastSeenAt: now
        ))
        // No album artist, deliberately: negative text rules have to cope with NULL.
        try seed(store, TrackRef(
            jellyfinId: "autumn", contentKey: "k3", title: "Autumn Leaves",
            artist: "Bill Evans", album: "Portrait in Jazz", albumArtist: nil,
            durationMs: 350_000, year: 1960, genres: ["Jazz", "Bebop"], lastSeenAt: now
        ))
        try seed(store, TrackRef(
            jellyfinId: "xtal", contentKey: "k4", title: "Xtal",
            artist: "Aphex Twin", album: "Selected Ambient Works", albumArtist: "Aphex Twin",
            durationMs: 293_000, year: 1992, genres: ["Electronic"], lastSeenAt: now
        ))

        for offset in [1, 40, 400] {
            try store.append(play("so-what", at: now - Millis(offset) * day, played: 545_000, completed: true))
        }
        try store.append(play("paranoid", at: now - 200 * day, played: 200_000))
        try store.append(play("paranoid", at: now - 3 * day, played: 10_000))
        try store.append(play("paranoid", at: now - 2 * day, played: 10_000))
        try store.append(play("autumn", at: now - 5 * day, played: 20_000))

        try store.record(Like(jellyfinId: "so-what", contentKey: "k1", liked: true, updatedAt: now, originDevice: ""))
        try store.record(Like(jellyfinId: "paranoid", contentKey: "k2", liked: false, updatedAt: now, originDevice: ""))
        // Soft-deleted, so it must read as unliked rather than as liked.
        try store.record(
            Like(jellyfinId: "autumn", contentKey: "k3", liked: true, updatedAt: now, originDevice: ""),
            deleted: true
        )

        return store
    }

    private func seed(_ store: CurationStore, _ track: TrackRef) throws {
        try store.writeLocal { try track.insert($0) }
    }

    private func play(_ trackId: String, at started: Millis, played: Int, completed: Bool = false) -> PlayEvent {
        PlayEvent(
            jellyfinId: trackId,
            contentKey: trackId,
            startedAt: started,
            endedAt: started + Millis(played),
            msPlayed: played,
            completed: completed,
            source: .album,
            originDevice: "phone"
        )
    }

    private func rules(
        _ match: SmartRules.Match = .all,
        _ clauses: [(SmartRule.Field, SmartRule.Operator, SmartRule.Value)],
        sort: SmartRules.Sort? = nil,
        limit: Int? = nil
    ) throws -> SmartRules {
        try SmartRules(
            match: match,
            rules: clauses.map { try SmartRule(field: $0.0, op: $0.1, value: $0.2) },
            sort: sort,
            limit: limit
        )
    }

    private func matches(
        _ store: CurationStore,
        _ match: SmartRules.Match = .all,
        _ clauses: [(SmartRule.Field, SmartRule.Operator, SmartRule.Value)],
        asOf instant: Millis? = nil
    ) throws -> [String] {
        try store.evaluate(rules(match, clauses), asOf: instant ?? now, calendar: utc)
    }

    // MARK: - Text operators

    @Test("text operators compare case-insensitively, as anyone typing an artist name expects")
    func textOperators() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.artist, .is, "miles davis")]) == ["so-what"])
        #expect(try matches(store, .all, [(.artist, .isNot, "Miles Davis")]) == ["autumn", "paranoid", "xtal"])
        #expect(try matches(store, .all, [(.title, .contains, "an")]) == ["paranoid"])
        #expect(try matches(store, .all, [(.album, .beginsWith, "kind")]) == ["so-what"])
        #expect(try matches(store, .all, [(.album, .doesNotContain, "jazz")]) == ["paranoid", "so-what", "xtal"])
    }

    /// `NOT (NULL = 'Radiohead')` is NULL, not true, so without coalescing the one
    /// track with no album artist — the most obvious member of the result — would be
    /// the only one missing from it.
    @Test("a missing album artist still satisfies 'is not'")
    func nullTextIsComparable() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.albumArtist, .isNot, "Radiohead")]) == ["autumn", "so-what", "xtal"])
    }

    /// Genres are an array, so the negative operators have to negate the whole
    /// existence test. Asking it inside would mean "has some genre that isn't Jazz",
    /// which the jazz records satisfy too.
    @Test("genre rules ask about any of a track's genres, and 'is not' about none of them")
    func genreOperators() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.genre, .is, "jazz")]) == ["autumn", "so-what"])
        #expect(try matches(store, .all, [(.genre, .isNot, "Jazz")]) == ["paranoid", "xtal"])
        #expect(try matches(store, .all, [(.genre, .contains, "rock")]) == ["paranoid"])
        #expect(try matches(store, .all, [(.genre, .beginsWith, "Elect")]) == ["xtal"])
        #expect(try matches(store, .all, [(.genre, .doesNotContain, "e")]) == ["so-what"])
    }

    // MARK: - Numeric operators

    @Test("numeric operators, including on a column that may be unknown")
    func numericOperators() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.year, .is, 1960)]) == ["autumn"])
        #expect(try matches(store, .all, [(.year, .greaterThan, 1990)]) == ["paranoid", "xtal"])
        #expect(try matches(store, .all, [(.year, .lessThan, 1960)]) == ["so-what"])
        #expect(try matches(store, .all, [(.durationMs, .greaterThan, 400_000)]) == ["so-what"])
        #expect(try matches(store, .all, [(.skipCount, .greaterThan, 1)]) == ["paranoid"])
    }

    /// The reason the aggregate is LEFT joined. A track nobody has played has a play
    /// count of zero, not "no row" — and an inner join would answer this rule with
    /// only the tracks that *have* been played, which is close to its opposite.
    @Test("a never-played track has played fewer than three times")
    func neverPlayedCountsAsZero() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.playCount, .lessThan, 3)]) == ["autumn", "paranoid", "xtal"])
        #expect(try matches(store, .all, [(.playCount, .is, 0)]) == ["autumn", "xtal"])
    }

    // MARK: - Dates

    /// `autumn` was skipped five days ago and appears in neither answer: a skip is
    /// not a play, so it does not move the last-played date.
    @Test("in the last / not in the last, resolved against the injected clock")
    func relativeDateOperators() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.lastPlayed, .inTheLast, "30d")]) == ["so-what"])
        #expect(try matches(store, .all, [(.lastPlayed, .notInTheLast, "30d")]) == ["autumn", "paranoid", "xtal"])
        #expect(try matches(store, .all, [(.firstPlayed, .before, "-1y")]) == ["so-what"])
        #expect(try matches(store, .all, [(.lastPlayed, .after, "-30d")]) == ["so-what"])
    }

    /// `before` asserts that a play happened; `notInTheLast` asserts that one didn't,
    /// which "never at all" satisfies. The difference is the whole value of a
    /// rediscovery playlist, so it is pinned here.
    @Test("'not in the last' includes never played, 'before' does not")
    func neverPlayedAgainstDates() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.lastPlayed, .before, "-30d")]) == ["paranoid"])
        #expect(try matches(store, .all, [(.lastPlayed, .notInTheLast, "-30d")]) == ["autumn", "paranoid", "xtal"])
    }

    /// The same rules against a different `now` give a different answer, which is
    /// what "resolved at evaluation time" has to mean — and what lets a rule editor
    /// preview a playlist as of some other moment.
    @Test("a relative rule moves with the clock it is evaluated against")
    func clockMoves() throws {
        let store = try library()
        // At `now` this matched so-what, whose last play was a day old. Forty days
        // later that play is 41 days old and the same rules match nothing — while a
        // year-wide window still reaches back past both.
        #expect(try matches(store, .all, [(.lastPlayed, .inTheLast, "30d")], asOf: now + 40 * day) == [])
        #expect(try matches(store, .all, [(.lastPlayed, .inTheLast, "1y")], asOf: now + 40 * day) == ["paranoid", "so-what"])
    }

    @Test("an absolute epoch millisecond is accepted where an instant is wanted")
    func absoluteDateBound() throws {
        let store = try library()
        let cutoff = SmartRule.Value.number(Int(now - 100 * day))
        #expect(try matches(store, .all, [(.lastPlayed, .after, cutoff)]) == ["so-what"])
    }

    // MARK: - Likes

    @Test("liked reads through the like table, and a soft-deleted like is not a like")
    func likedOperator() throws {
        let store = try library()
        #expect(try matches(store, .all, [(.liked, .is, true)]) == ["so-what"])
        #expect(try matches(store, .all, [(.liked, .is, false)]) == ["autumn", "paranoid", "xtal"])
        #expect(try matches(store, .all, [(.liked, .isNot, true)]) == ["autumn", "paranoid", "xtal"])
    }

    // MARK: - Combination, sort, limit

    @Test("all narrows and any widens")
    func matchModes() throws {
        let store = try library()
        let clauses: [(SmartRule.Field, SmartRule.Operator, SmartRule.Value)] = [
            (.genre, .is, "Jazz"),
            (.year, .greaterThan, 1990),
        ]
        #expect(try matches(store, .all, clauses) == [])
        #expect(try matches(store, .any, clauses) == ["autumn", "paranoid", "so-what", "xtal"])
    }

    @Test("sort and limit are applied by the database, not by the caller")
    func sortAndLimit() throws {
        let store = try library()

        let top = try rules(.all, [], sort: .init(field: .playCount, dir: .desc), limit: 2)
        #expect(try store.evaluate(top, asOf: now, calendar: utc) == ["so-what", "paranoid"])

        let byTitle = try rules(.all, [], sort: .init(field: .title, dir: .asc))
        #expect(try store.evaluate(byTitle, asOf: now, calendar: utc) == ["autumn", "paranoid", "so-what", "xtal"])

        // Never-played sorts last descending, and the two of them break their tie on
        // id rather than on whatever order SQLite happened to read them in.
        let recent = try rules(.all, [], sort: .init(field: .lastPlayed, dir: .desc))
        #expect(try store.evaluate(recent, asOf: now, calendar: utc) == ["so-what", "paranoid", "autumn", "xtal"])
    }

    @Test("no rules at all means every track, which is how a top-N playlist is written")
    func emptyAllMatchesEverything() throws {
        let store = try library()
        #expect(try matches(store, .all, []) == ["autumn", "paranoid", "so-what", "xtal"])
    }

    // MARK: - Injection

    /// The property this part lives or dies by. Rule values come from a text field,
    /// and one reaching SQLite as source rather than as an argument destroys data.
    @Test("a rule value that is SQL is treated as text")
    func sqlInjection() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let payload = "'; DROP TABLE playlist; --"
        try seed(store, TrackRef(
            jellyfinId: "bobby", contentKey: "kb", title: payload,
            artist: payload, album: "Exploits of a Mom", durationMs: 1000, lastSeenAt: now
        ))
        try seed(store, TrackRef(
            jellyfinId: "innocent", contentKey: "ki", title: "Innocent",
            artist: "Somebody", album: "Elsewhere", durationMs: 1000, lastSeenAt: now
        ))
        try store.record(Playlist(name: "Survivor", sortIndex: FractionalIndex.initial, updatedAt: now, originDevice: ""))

        #expect(try matches(store, .all, [(.artist, .is, .text(payload))]) == ["bobby"])
        #expect(try matches(store, .all, [(.title, .contains, "DROP TABLE")]) == ["bobby"])
        #expect(try matches(store, .all, [(.genre, .is, .text(payload))]) == [])
        #expect(try matches(store, .all, [(.album, .beginsWith, .text("' OR 1=1 --"))]) == [])

        let survivors = try store.read { try Playlist.fetchAll($0) }
        #expect(survivors.map(\.name) == ["Survivor"])
    }

    /// `%` and `_` are wildcards to SQLite and ordinary characters to whoever typed
    /// them. Unescaped, a rule for "100%" matches every title containing 100, and a
    /// rule for "_" matches the entire library.
    @Test("wildcards inside a rule value are literal")
    func likeWildcardsAreEscaped() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        try seed(store, TrackRef(
            jellyfinId: "endurance", contentKey: "ke", title: "100% Endurance",
            artist: "A", album: "A", durationMs: 1000, lastSeenAt: now
        ))
        try seed(store, TrackRef(
            jellyfinId: "years", contentKey: "ky", title: "100 Years",
            artist: "B", album: "B", durationMs: 1000, lastSeenAt: now
        ))

        #expect(try matches(store, .all, [(.title, .contains, "100%")]) == ["endurance"])
        #expect(try matches(store, .all, [(.title, .contains, "_")]) == [])
    }

    // MARK: - What counts as a play

    /// Half the track or four minutes, whichever comes first, and a skip only inside
    /// the first fifth. The gap between them is deliberate: a minute of a three
    /// minute track is neither a listen nor a rejection, and counting it as either
    /// would poison both the play count and the skip count.
    @Test("the play and skip thresholds")
    func playThresholds() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        for (id, duration) in [("short", 180_000), ("long", 1_200_000), ("unknown", nil as Int?)] {
            try seed(store, TrackRef(
                jellyfinId: id, contentKey: id, title: id, artist: "A", album: "A",
                durationMs: duration, lastSeenAt: now
            ))
        }

        try store.append(play("short", at: now - day, played: 90_000))          // exactly half: a play
        try store.append(play("short", at: now - 2 * day, played: 60_000))      // neither
        try store.append(play("short", at: now - 3 * day, played: 30_000))      // under a fifth: a skip
        try store.append(play("long", at: now - day, played: 240_000))          // four minutes of twenty
        // With no duration the rule falls back to the four-minute ceiling and to a
        // fifth of it — 48 seconds — for the skip. Ten seconds of an unmeasurable
        // track is still plainly a rejection, and `PlayClassifier` writes exactly that
        // verdict onto the row when the player reports one.
        try store.append(play("unknown", at: now - day, played: 10_000))        // under 48s: a skip
        try store.append(play("unknown", at: now - 2 * day, played: 300_000))   // four minutes is enough alone

        #expect(try matches(store, .all, [(.playCount, .is, 1)]) == ["long", "short", "unknown"])
        #expect(try matches(store, .all, [(.skipCount, .is, 1)]) == ["short", "unknown"])
        #expect(try matches(store, .all, [(.skipCount, .is, 0)]) == ["long"])
    }

    // MARK: - The stored JSON

    @Test("the document's own example decodes and evaluates")
    func documentExample() throws {
        let json = """
        {
          "match": "all",
          "rules": [
            { "field": "genre",       "op": "is",     "value": "Jazz" },
            { "field": "play_count",  "op": ">=",     "value": 3 },
            { "field": "last_played", "op": "before", "value": "-30d" }
          ],
          "sort":  { "field": "last_played", "dir": "desc" },
          "limit": 100
        }
        """
        let decoded = try SmartRules(json: json)
        #expect(decoded.rules.count == 3)
        // `>= 3` has no operator of its own and becomes the exact strict equivalent,
        // which is exact rather than approximate because a play count is an integer.
        #expect(decoded.rules[1].op == .greaterThan)
        #expect(decoded.rules[1].value == .number(2))

        let store = try library()
        #expect(try store.evaluate(decoded, asOf: now, calendar: utc) == [])
        #expect(try store.evaluate(decoded, asOf: now + 60 * day, calendar: utc) == ["so-what"])
    }

    @Test("rules round-trip through the document's field spelling")
    func roundTrip() throws {
        let original = try rules(
            .any,
            [(.playCount, .greaterThan, 5), (.lastPlayed, .notInTheLast, "-6m")],
            sort: .init(field: .lastPlayed, dir: .desc),
            limit: 25
        )
        let json = try original.json()
        #expect(json.contains("\"play_count\""))
        #expect(json.contains("\"last_played\""))
        #expect(try SmartRules(json: json) == original)
    }

    @Test("camelCase field names are accepted on the way in")
    func camelCaseAliases() throws {
        let json = """
        { "match": "all", "rules": [{ "field": "playCount", "op": "greaterThan", "value": 1 }] }
        """
        #expect(try SmartRules(json: json).rules[0].field == .playCount)
    }

    // MARK: - Rejecting the impossible

    /// Every one of these is a rule set that could be given a meaning-free
    /// implementation returning nothing. None of them is: an empty smart playlist is
    /// indistinguishable from a broken one, so a broken one has to say so.
    @Test("illegal rules are refused rather than quietly matching nothing")
    func illegalRulesAreRejected() throws {
        #expect(throws: SmartPlaylistError.operatorNotApplicable(field: .playCount, op: .contains)) {
            try SmartRule(field: .playCount, op: .contains, value: "3")
        }
        #expect(throws: SmartPlaylistError.operatorNotApplicable(field: .title, op: .inTheLast)) {
            try SmartRule(field: .title, op: .inTheLast, value: "30d")
        }
        #expect(throws: SmartPlaylistError.valueTypeMismatch(field: .title, op: .is)) {
            try SmartRule(field: .title, op: .is, value: 3)
        }
        #expect(throws: SmartPlaylistError.valueTypeMismatch(field: .liked, op: .is)) {
            try SmartRule(field: .liked, op: .is, value: "yes")
        }
        // A span in unstated units is not a span.
        #expect(throws: SmartPlaylistError.valueTypeMismatch(field: .lastPlayed, op: .inTheLast)) {
            try SmartRule(field: .lastPlayed, op: .inTheLast, value: 30)
        }
        #expect(throws: SmartPlaylistError.malformedInterval("a fortnight")) {
            try SmartRule(field: .lastPlayed, op: .inTheLast, value: "a fortnight")
        }
        #expect(throws: SmartPlaylistError.noRules) {
            try SmartRules(match: .any, rules: [])
        }
        #expect(throws: SmartPlaylistError.nonPositiveLimit(0)) {
            try SmartRules(rules: [], limit: 0)
        }
        #expect(throws: SmartPlaylistError.fieldNotSortable(.genre)) {
            let store = try CurationStore.inMemory()
            let byGenre = try SmartRules(rules: [], sort: .init(field: .genre, dir: .asc))
            _ = try store.evaluate(byGenre, asOf: now, calendar: utc)
        }
    }

    @Test("unknown fields and operators are named, not ignored")
    func unknownNames() throws {
        #expect(throws: SmartPlaylistError.unknownField("titel")) {
            try SmartRules(json: #"{"match":"all","rules":[{"field":"titel","op":"is","value":"x"}]}"#)
        }
        #expect(throws: SmartPlaylistError.unknownOperator("soundsLike")) {
            try SmartRules(json: #"{"match":"all","rules":[{"field":"title","op":"soundsLike","value":"x"}]}"#)
        }
        // A field name is mapped through the enum, never spliced into SQL, so this
        // is a naming error long before it could be anything worse.
        #expect(throws: SmartPlaylistError.unknownField("title FROM track; DROP TABLE track; --")) {
            try SmartRules(json: #"{"match":"all","rules":[{"field":"title FROM track; DROP TABLE track; --","op":"is","value":"x"}]}"#)
        }
        #expect(throws: SmartPlaylistError.malformedValue) {
            try SmartRules(json: #"{"match":"all","rules":[{"field":"year","op":"is","value":1959.5}]}"#)
        }
    }

    // MARK: - Relative intervals

    @Test("months and years are calendar arithmetic, not multiples of a day")
    func calendarArithmetic() throws {
        let calendar = utc
        func instant(_ year: Int, _ month: Int, _ day: Int) throws -> Millis {
            let components = DateComponents(year: year, month: month, day: day, hour: 12)
            return try #require(calendar.date(from: components)).millis
        }

        let endOfMarch = try instant(2024, 3, 31)
        #expect(try RelativeInterval.parse("-1m").ago(endOfMarch, calendar: calendar) == instant(2024, 2, 29))
        #expect(try RelativeInterval.parse("-1y").ago(endOfMarch, calendar: calendar) == instant(2023, 3, 31))
        #expect(try RelativeInterval.parse("-30d").ago(endOfMarch, calendar: calendar) == endOfMarch - 30 * day)
        #expect(try RelativeInterval.parse("-2w").ago(endOfMarch, calendar: calendar) == endOfMarch - 14 * day)
    }

    @Test("intervals parse with or without the leading minus, and refuse anything else")
    func intervalParsing() throws {
        #expect(try RelativeInterval.parse("-6m") == RelativeInterval(amount: 6, unit: .months))
        #expect(try RelativeInterval.parse("6m") == RelativeInterval(amount: 6, unit: .months))
        #expect(try RelativeInterval.parse(" -1Y ") == RelativeInterval(amount: 1, unit: .years))
        for bad in ["banana", "30", "d", "3.5d", "--3d", "30 days", ""] {
            #expect(throws: SmartPlaylistError.malformedInterval(bad)) { try RelativeInterval.parse(bad) }
        }
    }

    // MARK: - Playlists

    @Test("rules attached to a playlist come back out of it")
    func playlistRoundTrip() throws {
        let store = try library()
        let set = try rules(.all, [(.genre, .is, "Jazz")], sort: .init(field: .title, dir: .asc))
        let playlist = try Playlist(
            name: "Jazz", sortIndex: FractionalIndex.initial, updatedAt: now, originDevice: ""
        ).settingSmartRules(set)
        let saved = try store.record(playlist)

        #expect(saved.isSmart)
        #expect(try saved.smartRuleSet() == set)
        #expect(try store.resolve(playlist: saved, asOf: now, calendar: utc) == ["autumn", "so-what"])
        // The rules travel, because they went through `record` like any other change.
        #expect(try store.pendingOps().contains { $0.entityId == saved.id && $0.payload.contains("smartRules") })
    }

    @Test("resolving a playlist that carries no rules is an error, not an empty list")
    func resolvingAPlainPlaylist() throws {
        let store = try library()
        let plain = Playlist(name: "Hand-made", sortIndex: FractionalIndex.initial, updatedAt: now, originDevice: "")
        #expect(throws: SmartPlaylistError.notSmart(playlistId: plain.id)) {
            try store.resolve(playlist: plain, asOf: now, calendar: utc)
        }
        #expect(try plain.smartRuleSet() == nil)
    }

    // MARK: - Counting without listing

    /// The list screen wants a number, not the songs, and it asks once per smart
    /// playlist after every mutation of any playlist. The count has to be the same
    /// number `evaluate` would produce or the subtitle is simply wrong — so it is
    /// checked against it across the shapes that could diverge, `LIMIT` above all,
    /// which a separately written `COUNT(*)` would silently ignore.
    @Test("the count agrees with the list it is not building")
    func matchCountTracksEvaluate() throws {
        let store = try library()
        let sets = [
            try rules(.all, []),
            try rules(.all, [(.genre, .is, "Jazz")]),
            try rules(.any, [(.playCount, .greaterThan, 1), (.liked, .is, true)]),
            try rules(.all, [(.playCount, .is, 0)]),
            try rules(.all, [(.artist, .is, "Nobody At All")]),
            try rules(.all, [], sort: .init(field: .playCount, dir: .desc), limit: 2),
            try rules(.all, [(.genre, .is, "Jazz")], sort: .init(field: .title, dir: .asc), limit: 1),
            // A limit larger than the result set must not be reported as the limit.
            try rules(.all, [(.genre, .is, "Electronic")], limit: 50)
        ]

        for set in sets {
            let listed = try store.evaluate(set, asOf: now, calendar: utc).count
            #expect(try store.matchCount(set, asOf: now, calendar: utc) == listed)
        }
    }

    @Test("counting a playlist that carries no rules is an error, like resolving one")
    func countingAPlainPlaylist() throws {
        let store = try library()
        let plain = Playlist(name: "Hand-made", sortIndex: FractionalIndex.initial, updatedAt: now, originDevice: "")
        #expect(throws: SmartPlaylistError.notSmart(playlistId: plain.id)) {
            try store.matchCount(playlist: plain, asOf: now, calendar: utc)
        }
    }
}
