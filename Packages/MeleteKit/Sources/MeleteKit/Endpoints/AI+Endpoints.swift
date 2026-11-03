import Foundation

/// What `/api/v1/ai/music/search` made of a phrase: filters for the library to
/// run, never tracks. The genres are ones the library has, spelled its way.
public struct MusicFilters: Decodable, Equatable, Sendable {
    /// The order the listener asked for.
    public enum Ordering: String, Decodable, Sendable {
        case byName = "by_name"
        case mostPlayed = "most_played"
        case newestFirst = "newest_first"
        case random
        case recentlyPlayed = "recently_played"

        var sort: ItemSort {
            switch self {
            case .byName: .name
            case .newestFirst: .releaseDate
            case .mostPlayed: .playCount
            case .recentlyPlayed: .datePlayed
            case .random: .random
            }
        }

        var direction: SortDirection {
            switch self {
            case .byName, .random: .ascending
            // "Newest", "most played" and "recently played" all mean the largest
            // value first; ascending would answer each of them backwards.
            case .newestFirst, .mostPlayed, .recentlyPlayed: .descending
            }
        }
    }

    /// Words to match names against, when the phrase named a song, album or artist.
    public let searchTerm: String?
    public let genres: [String]
    /// The period asked for, inclusive at both ends.
    public let fromYear: Int?
    public let toYear: Int?
    public let likedOnly: Bool
    public let ordering: Ordering

    /// The filters as a query for ``MeleteClient/songs(matching:)``.
    public var query: MusicQuery {
        let term = searchTerm?.trimmingCharacters(in: .whitespaces)
        return MusicQuery(
            searchTerm: term?.isEmpty == false ? term : nil,
            genres: genres,
            years: MusicQuery.years(from: fromYear, to: toYear),
            favoritesOnly: likedOnly,
            sort: ordering.sort,
            direction: ordering.direction
        )
    }
}

/// What `/api/v1/ai/music/mix` made of a mood: smart-playlist rules in Aoide's
/// own format, the names the description mentioned, and the rules Melete left
/// out, each with why.
public struct MusicMix: Decodable, Equatable, Sendable {
    public struct RuleSet: Decodable, Equatable, Sendable {
        /// `all` or `any`.
        public let match: String
        /// Nil for no cap.
        public let limit: Int?
        public let rules: [Rule]
    }

    /// One rule as a playlist's `smartRules` spells it: the field in snake_case
    /// (`last_played`), the operator in camelCase (`notInTheLast`).
    public struct Rule: Decodable, Equatable, Sendable {
        public let field: String
        public let op: String
        public let value: Value
    }

    public enum Value: Decodable, Equatable, Sendable {
        case text(String)
        case number(Int)
        case flag(Bool)

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .flag(flag)
            } else if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }
    }

    /// Artists, albums, games, films or shows the description named: the half of
    /// a mood no rule can say ("Helldivers 2 session music").
    public let names: [String]
    /// Nil when nothing usable was left.
    public let rules: RuleSet?
    public let rejected: [String]
}

extension MeleteClient {
    // MARK: - AI

    /// Whether the server offers its AI features, which an admin turns on by
    /// giving it an OpenRouter key. A server without them at all (an older or
    /// music-only Melete) answers 403 or 404, which ``MeleteError/meansAIOff``.
    public func aiEnabled() async throws -> Bool {
        struct About: Decodable { let enabled: Bool }
        return try await get(About.self, path: "api/v1/ai").enabled
    }

    /// `phrase` as filters over the library. Melete sends the words, and the names
    /// of the genres this user may see, to OpenRouter; nothing else about the
    /// library or the user. Counts as one of the user's AI requests this hour.
    public func musicFilters(describing phrase: String) async throws -> MusicFilters {
        struct Ask: Encodable { let query: String }
        return try await post(MusicFilters.self, path: "api/v1/ai/music/search", body: Ask(query: phrase))
    }

    /// A mood as smart-playlist rules, sent to OpenRouter as ``musicFilters(describing:)``
    /// sends a phrase, and counted with it.
    public func musicMix(describing description: String) async throws -> MusicMix {
        struct Ask: Encodable { let description: String }
        return try await post(MusicMix.self, path: "api/v1/ai/music/mix", body: Ask(description: description))
    }
}

extension MeleteError {
    /// Whether an AI route's failure means the server has AI off: 503 while it
    /// has no OpenRouter key, 403 or 404 from a server without the route (one
    /// older than the music AI answers 404 to it even with AI on).
    public var meansAIOff: Bool {
        switch self {
        case .forbidden, .notFound: true
        case .http(status: 503, _, _): true
        default: false
        }
    }
}
