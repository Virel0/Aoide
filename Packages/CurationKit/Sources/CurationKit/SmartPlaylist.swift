import Foundation
import GRDB

// MARK: - Rule model

/// One clause of a smart playlist: a field, an operator, and a value to compare
/// against.
///
/// Constructing one is fallible on purpose. Most of the field/operator pairs that can
/// be spelled are nonsense — a duration cannot begin with something, a title is not
/// in the last six months — and the cheap implementation of "unsupported" is a
/// predicate that matches nothing. That is the worst possible failure here: a smart
/// playlist that is quietly empty looks exactly like one whose rules simply have no
/// hits, and the user has no way to tell which they are looking at. So an illegal
/// combination cannot survive either construction path, in Swift or from JSON.
public struct SmartRule: Codable, Hashable, Sendable {

    /// The columns a rule may talk about.
    ///
    /// The raw values are the spellings in docs/sync-design.md, which is what the
    /// sidecar will be written against, so those are the only ones ever emitted.
    public enum Field: String, Codable, Hashable, Sendable, CaseIterable {
        case title, artist, album
        case albumArtist = "album_artist"
        case genre
        case year
        case durationMs = "duration_ms"
        case playCount = "play_count"
        case skipCount = "skip_count"
        case lastPlayed = "last_played"
        case firstPlayed = "first_played"
        case liked

        /// What kind of value the field holds, which is the whole of what decides
        /// which operators may apply to it.
        enum Kind { case text, number, date, flag }

        var kind: Kind {
            switch self {
            case .title, .artist, .album, .albumArtist, .genre: .text
            case .year, .durationMs, .playCount, .skipCount: .number
            case .lastPlayed, .firstPlayed: .date
            case .liked: .flag
            }
        }

        /// Rules written by hand or by the app spell fields in camelCase; the design
        /// document spells them in snake_case. Accepting both inbound costs one
        /// dictionary and removes a whole class of "the playlist is empty and I don't
        /// know why".
        private static let aliases: [String: Field] = [
            "albumArtist": .albumArtist,
            "durationMs": .durationMs,
            "playCount": .playCount,
            "skipCount": .skipCount,
            "lastPlayed": .lastPlayed,
            "firstPlayed": .firstPlayed,
        ]

        init(wire: String) throws {
            guard let field = Field(rawValue: wire) ?? Field.aliases[wire] else {
                throw SmartPlaylistError.unknownField(wire)
            }
            self = field
        }

        public init(from decoder: any Decoder) throws {
            try self.init(wire: decoder.singleValueContainer().decode(String.self))
        }
    }

    /// The closed set of comparisons. Closed is the point: these names are mapped to
    /// SQL through a `switch`, never interpolated, so an operator that is not in this
    /// enum cannot reach the database in any form.
    public enum Operator: String, Codable, Hashable, Sendable, CaseIterable {
        case `is`, isNot, contains, doesNotContain, beginsWith
        case greaterThan, lessThan
        case before, after, inTheLast, notInTheLast

        /// Symbolic spellings, as used in the design document's example, and how far
        /// off the canonical name each one lands.
        ///
        /// `>=` and `<=` have no operator of their own, and translate exactly rather
        /// than approximately: every comparable field here is integral — counts, a
        /// year, milliseconds — so `>= n` *is* `> n - 1`. Shifting the bound is
        /// cheaper than two more operators for every rule editor to render.
        private static let symbols: [String: (Operator, Int)] = [
            "=": (.is, 0), "==": (.is, 0),
            "!=": (.isNot, 0), "<>": (.isNot, 0),
            ">": (.greaterThan, 0), "<": (.lessThan, 0),
            ">=": (.greaterThan, -1), "<=": (.lessThan, 1),
        ]

        static func resolve(_ wire: String) throws -> (op: Operator, bias: Int) {
            if let op = Operator(rawValue: wire) { return (op, 0) }
            guard let symbol = Operator.symbols[wire] else {
                throw SmartPlaylistError.unknownOperator(wire)
            }
            return symbol
        }
    }

    /// Integers only, never a floating point number: every numeric field here counts
    /// something or is a millisecond, and accepting `2.5` would mean deciding on the
    /// user's behalf which way to round a bound.
    public enum Value: Codable, Hashable, Sendable {
        case text(String)
        case number(Int)
        case flag(Bool)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            // Bool first: a JSON `true` would not decode as Int anyway, but the order
            // states the intent rather than relying on the decoder's error behaviour.
            if let flag = try? container.decode(Bool.self) { self = .flag(flag); return }
            if let number = try? container.decode(Int.self) { self = .number(number); return }
            if let text = try? container.decode(String.self) { self = .text(text); return }
            throw SmartPlaylistError.malformedValue
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .number(let number): try container.encode(number)
            case .flag(let flag): try container.encode(flag)
            }
        }
    }

    public let field: Field
    public let op: Operator
    public let value: Value

    enum CodingKeys: String, CodingKey { case field, op, value }

    public init(field: Field, op: Operator, value: Value) throws {
        try Self.check(field: field, op: op, value: value)
        self.field = field
        self.op = op
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let field = try container.decode(Field.self, forKey: .field)
        let (op, bias) = try Operator.resolve(container.decode(String.self, forKey: .op))
        var value = try container.decode(Value.self, forKey: .value)
        if bias != 0 {
            guard case .number(let bound) = value else {
                throw SmartPlaylistError.valueTypeMismatch(field: field, op: op)
            }
            value = .number(bound + bias)
        }
        try self.init(field: field, op: op, value: value)
    }

    private static func check(field: Field, op: Operator, value: Value) throws {
        func require(_ ops: [Operator]) throws {
            guard ops.contains(op) else {
                throw SmartPlaylistError.operatorNotApplicable(field: field, op: op)
            }
        }
        let mismatch = SmartPlaylistError.valueTypeMismatch(field: field, op: op)

        switch field.kind {
        case .text:
            try require([.is, .isNot, .contains, .doesNotContain, .beginsWith])
            guard case .text = value else { throw mismatch }
        case .number:
            try require([.is, .isNot, .greaterThan, .lessThan])
            guard case .number = value else { throw mismatch }
        case .date:
            try require([.before, .after, .inTheLast, .notInTheLast])
            switch (op, value) {
            // `before`/`after` name an instant, which may be given relatively or as
            // an absolute epoch millisecond; `inTheLast` names a span, and a bare
            // number would be a span in unstated units.
            case (.before, .number), (.after, .number):
                break
            case (_, .text(let written)):
                _ = try RelativeInterval.parse(written)
            default:
                throw mismatch
            }
        case .flag:
            try require([.is, .isNot])
            guard case .flag = value else { throw mismatch }
        }
    }
}

/// The rule set stored as JSON in `playlist.smartRules`.
///
/// Evaluated locally against SQLite, so a smart playlist works on a plane and updates
/// the instant a play event lands rather than whenever a server next recomputes it.
public struct SmartRules: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Hashable, Sendable { case all, any }

    public struct Sort: Codable, Hashable, Sendable {
        public enum Direction: String, Codable, Hashable, Sendable { case asc, desc }

        public var field: SmartRule.Field
        public var dir: Direction

        public init(field: SmartRule.Field, dir: Direction) {
            self.field = field
            self.dir = dir
        }
    }

    public let match: Match
    public let rules: [SmartRule]
    public let sort: Sort?
    public let limit: Int?

    enum CodingKeys: String, CodingKey { case match, rules, sort, limit }

    public init(match: Match = .all, rules: [SmartRule], sort: Sort? = nil, limit: Int? = nil) throws {
        // `all` of nothing is every track, which is a real playlist — "everything,
        // by play count, top 25". `any` of nothing can only ever be empty, and an
        // always-empty playlist is indistinguishable from a broken one, so it is
        // refused instead of shipped.
        if match == .any && rules.isEmpty { throw SmartPlaylistError.noRules }
        if let limit, limit <= 0 { throw SmartPlaylistError.nonPositiveLimit(limit) }

        self.match = match
        self.rules = rules
        self.sort = sort
        self.limit = limit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            match: container.decode(Match.self, forKey: .match),
            rules: container.decode([SmartRule].self, forKey: .rules),
            sort: container.decodeIfPresent(Sort.self, forKey: .sort),
            limit: container.decodeIfPresent(Int.self, forKey: .limit)
        )
    }

    public init(json: String) throws {
        self = try JSONDecoder().decode(SmartRules.self, from: Data(json.utf8))
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        // Stable key order, for the same reason the op payloads have it: these
        // strings are compared and diffed, and a dictionary's iteration order would
        // make an unchanged rule set look edited.
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

// MARK: - Relative dates

/// A span written the way rules store it: `-30d`, `-6m`, `1y`.
///
/// Kept relative all the way to evaluation. Resolving it when the rule is *written*
/// and storing the resulting instant would freeze "not played in a month" to one
/// particular month, and the playlist would stop moving the day it was created.
public struct RelativeInterval: Hashable, Sendable {
    public enum Unit: String, Hashable, Sendable, CaseIterable {
        case hours = "h", days = "d", weeks = "w", months = "m", years = "y"

        var component: Calendar.Component {
            switch self {
            case .hours: .hour
            case .days: .day
            case .weeks: .weekOfYear
            case .months: .month
            case .years: .year
            }
        }
    }

    public let amount: Int
    public let unit: Unit

    public init(amount: Int, unit: Unit) {
        self.amount = amount
        self.unit = unit
    }

    /// Parses `-30d` or `30d`. The leading minus is decoration — the operator already
    /// carries the direction, and every one of them looks backwards in time — so both
    /// spellings mean the same span into the past.
    public static func parse(_ written: String) throws -> RelativeInterval {
        var body = Substring(written.trimmingCharacters(in: .whitespaces).lowercased())
        if body.first == "-" { body.removeFirst() }
        guard let suffix = body.last, let unit = Unit(rawValue: String(suffix)) else {
            throw SmartPlaylistError.malformedInterval(written)
        }
        let digits = body.dropLast()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let amount = Int(digits) else {
            throw SmartPlaylistError.malformedInterval(written)
        }
        return RelativeInterval(amount: amount, unit: unit)
    }

    /// The instant this far before `now`.
    ///
    /// Calendar arithmetic rather than a multiple of 86 400 000: a month before 31
    /// March is 28 February, and counting 30-day months would drift most of a week
    /// over a year — enough to move tracks in and out of a "last 6 months" playlist
    /// for no reason. The calendar is a parameter because that arithmetic depends on
    /// a time zone, and a test using the machine's would pass in London and fail in
    /// Auckland.
    public func ago(_ now: Millis, calendar: Calendar) -> Millis {
        let reference = Date(timeIntervalSince1970: Double(now) / 1000)
        let shifted = calendar.date(byAdding: unit.component, value: -amount, to: reference) ?? reference
        return Millis((shifted.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - Evaluation

public extension CurationStore {

    /// The Jellyfin ids matching `rules`, in the rule set's own order.
    ///
    /// `now` is a parameter rather than a call to `Date()` inside, for two reasons
    /// that turn out to be the same one: a test cannot be deterministic otherwise,
    /// and a rule editor wants to preview what a playlist *would* contain as of some
    /// other moment.
    func evaluate(
        _ rules: SmartRules,
        asOf now: Millis = Date().millis,
        calendar: Calendar = .current
    ) throws -> [String] {
        let query = try SmartQuery(rules: rules, now: now, calendar: calendar)
        return try read { db in
            try String.fetchAll(db, sql: query.sql, arguments: query.arguments)
        }
    }

    /// How many tracks `rules` match, without building the list of them.
    ///
    /// The playlist list screen prints one number per smart playlist and throws the ids
    /// away, and it reloads after every mutation of *any* playlist — so counting through
    /// `evaluate` meant materialising a twenty-thousand-element array of ids to render
    /// the word "20,000", once per smart playlist, every time a song was added to an
    /// unrelated manual one.
    ///
    /// The compiled statement is wrapped rather than compiled a second way, so the count
    /// cannot drift from what `evaluate` would return — `LIMIT` included, which a
    /// hand-written `COUNT(*)` would have quietly ignored.
    func matchCount(
        _ rules: SmartRules,
        asOf now: Millis = Date().millis,
        calendar: Calendar = .current
    ) throws -> Int {
        let query = try SmartQuery(rules: rules, now: now, calendar: calendar)
        return try read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM (\(query.sql))",
                arguments: query.arguments
            ) ?? 0
        }
    }

    /// Evaluates a playlist's stored rules.
    ///
    /// Throws rather than returning `[]` when the playlist carries no rules: an empty
    /// result and a broken playlist render identically, and only one of them is worth
    /// waking somebody up about.
    func resolve(
        playlist: Playlist,
        asOf now: Millis = Date().millis,
        calendar: Calendar = .current
    ) throws -> [String] {
        try evaluate(rules(of: playlist), asOf: now, calendar: calendar)
    }

    /// `matchCount` for a playlist's stored rules.
    func matchCount(
        playlist: Playlist,
        asOf now: Millis = Date().millis,
        calendar: Calendar = .current
    ) throws -> Int {
        try matchCount(rules(of: playlist), asOf: now, calendar: calendar)
    }

    private func rules(of playlist: Playlist) throws -> SmartRules {
        guard playlist.isSmart, let json = playlist.smartRules, !json.isEmpty else {
            throw SmartPlaylistError.notSmart(playlistId: playlist.id)
        }
        return try SmartRules(json: json)
    }
}

public extension Playlist {
    /// A copy marked smart and carrying `rules`.
    ///
    /// Deliberately does not write: `CurationStore.record` is the only path that also
    /// writes the op, and a rule change that never syncs is a playlist that means
    /// different things on two devices.
    func settingSmartRules(_ rules: SmartRules) throws -> Playlist {
        var copy = self
        copy.isSmart = true
        copy.smartRules = try rules.json()
        return copy
    }

    func smartRuleSet() throws -> SmartRules? {
        guard isSmart, let smartRules, !smartRules.isEmpty else { return nil }
        return try SmartRules(json: smartRules)
    }
}

// MARK: - Compilation to SQL

/// A rule set compiled into one statement and its bound arguments.
///
/// One statement, not a fetch-and-filter loop: the alternative pulls the entire
/// library into memory to test four predicates against it, and does so again every
/// time a play event lands.
///
/// Every rule *value* is a bound parameter and every field and operator is mapped to
/// SQL through a `switch` over a closed enum. Nothing a user types is ever spliced
/// into the statement text — a rule value reaching SQLite as source is a data-loss
/// bug, and rule values come straight from a text field.
struct SmartQuery: Sendable {
    let sql: String
    let arguments: StatementArguments

    init(rules: SmartRules, now: Millis, calendar: Calendar) throws {
        var predicates: [String] = []
        var values: [DatabaseValue] = []

        for rule in rules.rules {
            let (fragment, bound) = try Self.predicate(for: rule, now: now, calendar: calendar)
            predicates.append("(\(fragment))")
            values.append(contentsOf: bound)
        }

        let filter = predicates.isEmpty
            ? "1"
            : predicates.joined(separator: rules.match == .all ? " AND " : " OR ")

        var tail = ""
        if let limit = rules.limit {
            tail = "LIMIT ?"
            values.append(limit.databaseValue)
        }

        // The join to `track` inside the aggregate is there because what counts as a
        // play depends on the track's duration. The join *outside* it is a LEFT join
        // and that is not cosmetic: a track nobody has played has a play count of
        // zero, not "no row", and an inner join would drop exactly the tracks a
        // "played fewer than three times" rule is asking about — the rule would
        // return only tracks that had been played, which is the opposite of what it
        // says. Likes join the same way, so unliked and never-touched agree.
        // What counts as a play and what counts as a skip come from `PlayDefinition`,
        // the same fragments `CurationStore.stats` aggregates with. That is not tidiness
        // — it is the whole reason a "played more than five times" playlist and the
        // count printed beside the track agree. `d` is this query's alias for the track
        // cache, distinct from the `t` the rules themselves read.
        //
        // LEFT, not INNER: the fragments are written to fall back to the duration-free
        // half of the rule when the cache has nothing to say, and an inner join would
        // instead drop the event and silently answer zero.
        let play = PlayDefinition.countsAsPlay(event: "e", track: "d")
        let skip = PlayDefinition.countsAsSkip(event: "e", track: "d")

        sql = """
        WITH history AS (
            SELECT
                e.jellyfinId AS jellyfinId,
                SUM(CASE WHEN \(play) THEN 1 ELSE 0 END) AS playCount,
                SUM(CASE WHEN \(skip) THEN 1 ELSE 0 END) AS skipCount,
                MAX(CASE WHEN \(play) THEN e.startedAt END) AS lastPlayed,
                MIN(CASE WHEN \(play) THEN e.startedAt END) AS firstPlayed
            FROM playEvent e
            LEFT JOIN track d ON d.jellyfinId = e.jellyfinId
            GROUP BY e.jellyfinId
        )
        SELECT t.jellyfinId
        FROM track t
        LEFT JOIN history h ON h.jellyfinId = t.jellyfinId
        LEFT JOIN "like" l ON l.jellyfinId = t.jellyfinId AND l.deleted = 0
        WHERE \(filter)
        ORDER BY \(try Self.order(rules.sort))
        \(tail)
        """
        arguments = StatementArguments(values)
    }

    /// The SQL expression a field reads from.
    private static func column(_ field: SmartRule.Field) -> String {
        switch field {
        case .title: "t.title"
        case .artist: "t.artist"
        case .album: "t.album"
        // A comparison against NULL is NULL rather than true, so "album artist is not
        // X" would silently drop every track that has no album artist — the tracks
        // most obviously satisfying it. Coalescing makes absence something that can
        // be compared.
        case .albumArtist: "IFNULL(t.albumArtist, '')"
        case .genre: "t.genres"
        case .year: "t.year"
        case .durationMs: "t.durationMs"
        case .playCount: "COALESCE(h.playCount, 0)"
        case .skipCount: "COALESCE(h.skipCount, 0)"
        // Not coalesced, unlike the counts above: never played is not the same claim
        // as played at the epoch, and flattening them would put every unplayed track
        // at the top of a "least recently played" list.
        case .lastPlayed: "h.lastPlayed"
        case .firstPlayed: "h.firstPlayed"
        case .liked: "COALESCE(l.liked, 0)"
        }
    }

    private static func predicate(
        for rule: SmartRule,
        now: Millis,
        calendar: Calendar
    ) throws -> (String, [DatabaseValue]) {
        let column = column(rule.field)

        switch rule.field.kind {
        case .text:
            guard case .text(let text) = rule.value else {
                throw SmartPlaylistError.valueTypeMismatch(field: rule.field, op: rule.op)
            }
            return rule.field == .genre
                ? genre(rule.op, text)
                : self.text(rule.op, column: column, text)

        case .number:
            guard case .number(let bound) = rule.value else {
                throw SmartPlaylistError.valueTypeMismatch(field: rule.field, op: rule.op)
            }
            let argument = [bound.databaseValue]
            switch rule.op {
            case .is: return ("\(column) = ?", argument)
            // `year` and `durationMs` may be NULL, and `NOT (NULL = 1999)` is NULL:
            // without the first arm, "year is not 1999" would exclude the tracks
            // whose year nobody knows.
            case .isNot: return ("(\(column) IS NULL OR \(column) <> ?)", argument)
            case .greaterThan: return ("\(column) > ?", argument)
            case .lessThan: return ("\(column) < ?", argument)
            default: throw SmartPlaylistError.operatorNotApplicable(field: rule.field, op: rule.op)
            }

        case .date:
            let instant: Millis
            switch rule.value {
            case .text(let written): instant = try RelativeInterval.parse(written).ago(now, calendar: calendar)
            case .number(let absolute): instant = Millis(absolute)
            case .flag: throw SmartPlaylistError.valueTypeMismatch(field: rule.field, op: rule.op)
            }
            let argument = [instant.databaseValue]
            switch rule.op {
            // NULL fails both of these, which is intended: `before` and `after`
            // assert that a play happened, and a track that was never played did not
            // happen before anything.
            case .before: return ("\(column) < ?", argument)
            case .after: return ("\(column) > ?", argument)
            case .inTheLast: return ("\(column) >= ?", argument)
            // The deliberate asymmetry: "not played in the last month" plainly
            // includes "never played at all", and this operator is how a
            // rediscovery playlist finds the tracks that have never had a chance.
            case .notInTheLast: return ("(\(column) IS NULL OR \(column) < ?)", argument)
            default: throw SmartPlaylistError.operatorNotApplicable(field: rule.field, op: rule.op)
            }

        case .flag:
            guard case .flag(let flag) = rule.value else {
                throw SmartPlaylistError.valueTypeMismatch(field: rule.field, op: rule.op)
            }
            let argument = [flag.databaseValue]
            switch rule.op {
            case .is: return ("\(column) = ?", argument)
            case .isNot: return ("\(column) <> ?", argument)
            default: throw SmartPlaylistError.operatorNotApplicable(field: rule.field, op: rule.op)
            }
        }
    }

    private static func text(
        _ op: SmartRule.Operator,
        column: String,
        _ text: String
    ) -> (String, [DatabaseValue]) {
        switch op {
        // NOCASE so that "artist is beatles" finds The Beatles, which is what anyone
        // typing that meant. ASCII-only, as SQLite's NOCASE is.
        case .is: ("\(column) = ? COLLATE NOCASE", [text.databaseValue])
        case .isNot: ("\(column) <> ? COLLATE NOCASE", [text.databaseValue])
        case .contains: ("\(column) LIKE ? ESCAPE '\\'", [wildcarded(text, prefix: true, suffix: true)])
        case .doesNotContain: ("\(column) NOT LIKE ? ESCAPE '\\'", [wildcarded(text, prefix: true, suffix: true)])
        case .beginsWith: ("\(column) LIKE ? ESCAPE '\\'", [wildcarded(text, prefix: false, suffix: true)])
        // Unreachable: `SmartRule.check` rejects every other operator on a text field
        // before one can be constructed. Spelled as a false predicate rather than a
        // crash because a rule set arriving from a future version of the app is a
        // wrong answer, not a reason to take the process down.
        default: ("0", [])
        }
    }

    /// Genres are a JSON array, so every operator asks about *some* genre of the
    /// track, and the negative ones have to sit outside the `EXISTS`. Inside, "is not
    /// Jazz" would ask whether the track has some genre that isn't Jazz — true of
    /// nearly everything, including the jazz.
    private static func genre(_ op: SmartRule.Operator, _ text: String) -> (String, [DatabaseValue]) {
        let (test, argument): (String, [DatabaseValue]) = switch op {
        case .is, .isNot: ("g.value = ? COLLATE NOCASE", [text.databaseValue])
        case .contains, .doesNotContain: ("g.value LIKE ? ESCAPE '\\'", [wildcarded(text, prefix: true, suffix: true)])
        case .beginsWith: ("g.value LIKE ? ESCAPE '\\'", [wildcarded(text, prefix: false, suffix: true)])
        default: ("0", [])
        }
        let negated = op == .isNot || op == .doesNotContain
        return ("\(negated ? "NOT " : "")EXISTS (SELECT 1 FROM json_each(t.genres) AS g WHERE \(test))", argument)
    }

    /// A LIKE pattern whose only wildcards are the ones added here.
    ///
    /// `%` and `_` are wildcards to SQLite and ordinary characters to whoever typed
    /// them: without escaping, a rule for tracks containing "100%" would match every
    /// track containing "100", and one for "_" would match everything at all.
    private static func wildcarded(_ text: String, prefix: Bool, suffix: Bool) -> DatabaseValue {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return ((prefix ? "%" : "") + escaped + (suffix ? "%" : "")).databaseValue
    }

    /// There is always an order, even when the rules ask for none: a LIMIT over an
    /// unordered query takes an arbitrary subset that can differ between two runs of
    /// the same rules. `jellyfinId` is appended as a tiebreak for the same reason —
    /// ten tracks played three times each must not shuffle themselves every time the
    /// playlist is opened.
    private static func order(_ sort: SmartRules.Sort?) throws -> String {
        guard let sort else { return "t.title COLLATE NOCASE, t.jellyfinId" }
        // A track has any number of genres; "sorted by genre" has no answer, and
        // ordering by the raw JSON would produce one that looks like an answer.
        guard sort.field != .genre else { throw SmartPlaylistError.fieldNotSortable(.genre) }

        let expression = sort.field.kind == .text
            ? "\(column(sort.field)) COLLATE NOCASE"
            : column(sort.field)
        return "\(expression) \(sort.dir == .asc ? "ASC" : "DESC"), t.jellyfinId"
    }
}

// MARK: - Errors

public enum SmartPlaylistError: Error, Equatable, CustomStringConvertible {
    case unknownField(String)
    case unknownOperator(String)
    case operatorNotApplicable(field: SmartRule.Field, op: SmartRule.Operator)
    case valueTypeMismatch(field: SmartRule.Field, op: SmartRule.Operator)
    case malformedInterval(String)
    case malformedValue
    case noRules
    case nonPositiveLimit(Int)
    case fieldNotSortable(SmartRule.Field)
    case notSmart(playlistId: String)

    public var description: String {
        switch self {
        case .unknownField(let name):
            "no such rule field: \(name)"
        case .unknownOperator(let name):
            "no such rule operator: \(name)"
        case .operatorNotApplicable(let field, let op):
            "\(op.rawValue) cannot apply to \(field.rawValue)"
        case .valueTypeMismatch(let field, let op):
            "the value does not suit \(field.rawValue) \(op.rawValue)"
        case .malformedInterval(let written):
            "\(written) is not a relative interval; expected something like -30d, -6m or -1y"
        case .malformedValue:
            "a rule value must be a string, a whole number or a boolean"
        case .noRules:
            "matching any of no rules can never match anything"
        case .nonPositiveLimit(let limit):
            "a limit of \(limit) can never return anything"
        case .fieldNotSortable(let field):
            "\(field.rawValue) has no single value to sort by"
        case .notSmart(let playlistId):
            "playlist \(playlistId) carries no smart rules"
        }
    }
}

// MARK: - Literal conveniences

extension SmartRule.Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .flag(value) }
}
