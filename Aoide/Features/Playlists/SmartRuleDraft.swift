import CurationKit
import Foundation

/// The editable form of a smart-playlist rule.
///
/// `SmartRule` is immutable and its initialiser throws — deliberately, because most
/// field/operator pairs that can be spelled are nonsense and the package refuses to
/// store one. That is exactly wrong for an editor, where a half-built rule is the normal
/// state between two taps: changing the field to `Year` while the operator still says
/// `contains` has to be a moment the UI can be in, not a thrown error.
///
/// So the editor holds drafts and converts. The conversion is the only path to a stored
/// rule, which means the package's own validation stays the last word — if the tables
/// below ever drift from `SmartRule.check`, the result is a message on screen rather than
/// a playlist that is quietly empty forever.
struct SmartRuleDraft: Identifiable, Hashable {
    let id = UUID()
    var field: SmartRule.Field
    var op: SmartRule.Operator
    var text: String = ""
    var number: Int = 0
    var flag = true
    var intervalAmount: Int = 30
    var intervalUnit: RelativeInterval.Unit = .days

    init(field: SmartRule.Field = .playCount, op: SmartRule.Operator? = nil) {
        self.field = field
        self.op = op ?? SmartField.kind(of: field).operators[0]
    }

    var kind: SmartField.Kind { SmartField.kind(of: field) }

    /// Re-points the operator and the value after the field changes.
    ///
    /// Without this a field change would leave an operator the new field can't take, and
    /// the rule would fail to convert with an error naming a combination the listener
    /// never chose. Keeping the operator when it happens to be legal for both is what
    /// makes "play count is more than 5" survive a switch to "skip count".
    mutating func fieldDidChange() {
        let allowed = kind.operators
        if !allowed.contains(op) { op = allowed[0] }
        // The value is not carried across kinds: "Jazz" is not a number of plays.
        if kind != .text { text = "" }
    }

    /// The stored rule this draft describes.
    func rule() throws -> SmartRule {
        switch kind {
        case .text:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty text rule is the trap this whole editor exists to avoid:
            // `contains ""` matches every track and `is ""` matches none, and neither
            // reads as a mistake once the sheet is closed.
            guard !trimmed.isEmpty else { throw DraftError.emptyValue(SmartField.name(of: field)) }
            return try SmartRule(field: field, op: op, value: .text(trimmed))

        case .number:
            // Lengths are entered in seconds, because nobody thinks in milliseconds, and
            // stored in milliseconds, because that is what the column holds.
            let stored = field == .durationMs ? number * 1000 : number
            return try SmartRule(field: field, op: op, value: .number(stored))

        case .date:
            return try SmartRule(
                field: field,
                op: op,
                // Stored relative, never resolved to an instant here. Freezing "the last
                // six months" to one particular six months when the rule is written is
                // how a smart playlist stops moving the day it was made.
                value: .text("-\(max(1, intervalAmount))\(intervalUnit.rawValue)")
            )

        case .flag:
            return try SmartRule(field: field, op: op, value: .flag(flag))
        }
    }

    /// Rebuilds a draft from a stored rule, so an existing playlist opens in the editor
    /// showing what it actually says.
    init(_ rule: SmartRule) {
        self.init(field: rule.field, op: rule.op)
        switch rule.value {
        case .text(let value):
            if SmartField.kind(of: rule.field) == .date {
                let interval = (try? RelativeInterval.parse(value)) ?? RelativeInterval(amount: 30, unit: .days)
                intervalAmount = interval.amount
                intervalUnit = interval.unit
            } else {
                text = value
            }
        case .number(let value):
            number = rule.field == .durationMs ? value / 1000 : value
        case .flag(let value):
            flag = value
        }
    }

    enum DraftError: LocalizedError {
        case emptyValue(String)

        var errorDescription: String? {
            switch self {
            case .emptyValue(let field): "Fill in a value for the \(field) rule."
            }
        }
    }
}

/// What the editor needs to know about each rule field that the package doesn't say:
/// what to call it, what may be compared against it, and how to type a value.
enum SmartField {
    enum Kind: Hashable {
        case text, number, date, flag

        var operators: [SmartRule.Operator] {
            switch self {
            case .text: [.is, .isNot, .contains, .doesNotContain, .beginsWith]
            case .number: [.is, .isNot, .greaterThan, .lessThan]
            case .date: [.inTheLast, .notInTheLast, .before, .after]
            case .flag: [.is, .isNot]
            }
        }
    }

    /// The fields the editor offers.
    ///
    /// `liked` is in the rule model and is deliberately **not** here. Nothing in this app
    /// writes the `like` table yet — a like is Melete's, kept on the server — so every rule about it would match either
    /// nothing or everything, and an always-empty playlist is indistinguishable from a
    /// broken one. It comes back the day there is a local like to read.
    static let all: [SmartRule.Field] = [
        .title, .artist, .album, .albumArtist, .genre,
        .year, .durationMs, .playCount, .skipCount,
        .lastPlayed, .firstPlayed,
    ]

    /// Mirrors `SmartRule.Field.kind`, which is internal to the package. Kept as a
    /// `switch` with no default so a new field added there fails to compile here rather
    /// than silently landing in the wrong editor.
    static func kind(of field: SmartRule.Field) -> Kind {
        switch field {
        case .title, .artist, .album, .albumArtist, .genre: .text
        case .year, .durationMs, .playCount, .skipCount: .number
        case .lastPlayed, .firstPlayed: .date
        // Mapped even though the editor never offers it, so a rule set written by hand or
        // arriving from another device still renders as what it is instead of as a broken
        // text field.
        case .liked: .flag
        }
    }

    static func name(of field: SmartRule.Field) -> String {
        switch field {
        case .title: "Title"
        case .artist: "Artist"
        case .album: "Album"
        case .albumArtist: "Album Artist"
        case .genre: "Genre"
        case .year: "Year"
        case .durationMs: "Length"
        case .playCount: "Play Count"
        case .skipCount: "Skip Count"
        case .lastPlayed: "Last Played"
        case .firstPlayed: "First Played"
        case .liked: "Loved"
        }
    }

    static func name(of op: SmartRule.Operator) -> String {
        switch op {
        case .is: "is"
        case .isNot: "is not"
        case .contains: "contains"
        case .doesNotContain: "does not contain"
        case .beginsWith: "begins with"
        case .greaterThan: "is more than"
        case .lessThan: "is less than"
        case .before: "is before"
        case .after: "is after"
        case .inTheLast: "is in the last"
        case .notInTheLast: "is not in the last"
        }
    }

    /// The unit written after a number field, where one clarifies what is being asked.
    static func unit(of field: SmartRule.Field) -> String? {
        switch field {
        case .durationMs: "seconds"
        case .playCount, .skipCount: "times"
        default: nil
        }
    }

    static func name(of unit: RelativeInterval.Unit, plural: Bool) -> String {
        let singular = switch unit {
        case .hours: "hour"
        case .days: "day"
        case .weeks: "week"
        case .months: "month"
        case .years: "year"
        }
        return plural ? singular + "s" : singular
    }
}

/// The whole editable rule set: what the sheet binds to.
///
/// `Equatable` so the editor's live preview can hang off `.task(id:)` — any change to any
/// part of it re-runs the evaluation and cancels the one in flight.
struct SmartRulesDraft: Equatable {
    var match: SmartRules.Match = .all
    var rules: [SmartRuleDraft] = []
    var isSorted = false
    var sortField: SmartRule.Field = .playCount
    var sortDescending = true
    var isLimited = false
    var limit = 25

    init() {}

    init(_ rules: SmartRules) {
        match = rules.match
        self.rules = rules.rules.map(SmartRuleDraft.init)
        if let sort = rules.sort {
            isSorted = true
            sortField = sort.field
            sortDescending = sort.dir == .desc
        }
        if let limit = rules.limit {
            isLimited = true
            self.limit = limit
        }
    }

    /// Fields a rule set may be ordered by.
    ///
    /// `genre` is absent because a track has any number of them: "sorted by genre" has no
    /// answer, and the package refuses it rather than inventing one from the raw JSON.
    static let sortableFields = SmartField.all.filter { $0 != .genre }

    func build() throws -> SmartRules {
        try SmartRules(
            match: match,
            rules: rules.map { try $0.rule() },
            sort: isSorted
                ? SmartRules.Sort(field: sortField, dir: sortDescending ? .desc : .asc)
                : nil,
            limit: isLimited ? max(1, limit) : nil
        )
    }
}

// MARK: - Presets

/// Rule sets worth having without writing one.
///
/// Every one of these is built from the same model the editor produces — there is no
/// second, hidden kind of smart playlist — so a preset can be opened, read, and edited
/// like any other. They exist because the useful rule sets for a personal library are
/// mostly about listening history, and history is the part a listener can't see to write
/// rules against.
struct SmartPlaylistPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let symbol: String
    let blurb: String
    /// A closure rather than a stored `SmartRules`, because building one throws — the
    /// package validates every field/operator pair — and a `let` cannot. The alternative
    /// was force-trying at file scope, which turns a typo in a preset into a launch crash.
    let rules: @Sendable () throws -> SmartRules

    static let all: [SmartPlaylistPreset] = [
        SmartPlaylistPreset(
            id: "on-repeat",
            name: "On Repeat",
            symbol: "repeat",
            blurb: "Played at least five times, and recently."
        ) {
            try SmartRules(
                match: .all,
                rules: [
                    try SmartRule(field: .playCount, op: .greaterThan, value: .number(4)),
                    try SmartRule(field: .lastPlayed, op: .inTheLast, value: .text("-30d")),
                ],
                sort: SmartRules.Sort(field: .playCount, dir: .desc),
                limit: 25
            )
        },
        SmartPlaylistPreset(
            id: "most-played",
            name: "Most Played",
            symbol: "chart.bar.fill",
            blurb: "Everything you've actually listened through, most first."
        ) {
            try SmartRules(
                match: .all,
                rules: [try SmartRule(field: .playCount, op: .greaterThan, value: .number(0))],
                sort: SmartRules.Sort(field: .playCount, dir: .desc),
                limit: 100
            )
        },
        SmartPlaylistPreset(
            id: "never-played",
            name: "Never Played",
            symbol: "sparkles",
            blurb: "Songs in your library you've never heard."
        ) {
            // `is 0`, not "less than 1": the play count column coalesces a missing
            // history row to zero, so this is genuinely every untouched track rather than
            // only the ones with an event behind them.
            try SmartRules(
                match: .all,
                rules: [try SmartRule(field: .playCount, op: .is, value: .number(0))],
                sort: SmartRules.Sort(field: .artist, dir: .asc)
            )
        },
        SmartPlaylistPreset(
            id: "forgotten-favourites",
            name: "Forgotten Favourites",
            symbol: "clock.arrow.circlepath",
            blurb: "You played these a lot, and not for six months."
        ) {
            // The play-count clause is doing real work: `not in the last` deliberately
            // also matches tracks never played at all, and without a floor this would be
            // "songs you've never heard" wearing a misleading name.
            try SmartRules(
                match: .all,
                rules: [
                    try SmartRule(field: .playCount, op: .greaterThan, value: .number(2)),
                    try SmartRule(field: .lastPlayed, op: .notInTheLast, value: .text("-6m")),
                ],
                sort: SmartRules.Sort(field: .lastPlayed, dir: .asc),
                limit: 50
            )
        },
    ]
}
