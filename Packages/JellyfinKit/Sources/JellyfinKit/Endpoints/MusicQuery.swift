import Foundation

/// A library query assembled from parts rather than a single search string.
///
/// Jellyfin's `searchTerm` matches names and nothing else, so "upbeat rock from the
/// nineties" as a search term matches nothing at all — no track is called that. The
/// parts here map onto filters the server can actually evaluate, which is what makes
/// a phrase answerable: something else turns the words into this, and the server
/// still does the choosing.
public struct MusicQuery: Sendable, Equatable {
    /// Words to match against names. Only set when the phrase actually named a
    /// title or performer.
    public var searchTerm: String?
    /// Genre *names*, which is what Jellyfin's `genres` filter takes.
    public var genres: [String]
    public var years: [Int]
    public var favoritesOnly: Bool
    public var sort: ItemSort
    public var direction: SortDirection
    public var limit: Int

    public init(
        searchTerm: String? = nil,
        genres: [String] = [],
        years: [Int] = [],
        favoritesOnly: Bool = false,
        sort: ItemSort = .name,
        direction: SortDirection = .ascending,
        limit: Int = 60
    ) {
        self.searchTerm = searchTerm
        self.genres = genres
        self.years = years
        self.favoritesOnly = favoritesOnly
        self.sort = sort
        self.direction = direction
        self.limit = limit
    }

    /// Whether this constrains anything at all.
    ///
    /// An unconstrained query is not "everything" — it's a parse that understood
    /// nothing, and running it would return the library in alphabetical order as
    /// though that were an answer.
    public var isEmpty: Bool {
        searchTerm == nil && genres.isEmpty && years.isEmpty && !favoritesOnly
    }

    /// The most years a range may expand to.
    ///
    /// Jellyfin filters on a list of exact years, not a range, so "since the
    /// eighties" would otherwise put fifty values in the URL. Anything this wide is
    /// not really a date filter, so it's dropped rather than truncated — truncating
    /// would silently answer a different question.
    static let maxYearSpan = 40

    /// Expands an inclusive range into the list Jellyfin wants.
    public static func years(from: Int?, to: Int?) -> [Int] {
        let currentEra = 1900...2100
        switch (from, to) {
        case let (from?, to?) where from <= to:
            guard currentEra.contains(from), currentEra.contains(to), to - from < maxYearSpan else { return [] }
            return Array(from...to)
        case let (from?, nil) where currentEra.contains(from):
            return Array(from...min(from + maxYearSpan - 1, currentEra.upperBound))
        case let (nil, to?) where currentEra.contains(to):
            return Array(max(to - maxYearSpan + 1, currentEra.lowerBound)...to)
        default:
            return []
        }
    }
}

extension JellyfinClient {
    /// Songs matching a structured query.
    public func songs(matching query: MusicQuery, parentId: String? = nil) async throws -> [JellyfinItem] {
        let response: ItemsResponse = try await get(
            path: "Items",
            query: try queryItems(for: query, includeTypes: ["Audio"], parentId: parentId)
        )
        return response.items
    }

    /// Albums matching a structured query.
    public func albums(matching query: MusicQuery, parentId: String? = nil) async throws -> [JellyfinItem] {
        let response: ItemsResponse = try await get(
            path: "Items",
            query: try queryItems(for: query, includeTypes: ["MusicAlbum"], parentId: parentId)
        )
        return response.items
    }

    func queryItems(
        for query: MusicQuery,
        includeTypes: [String],
        parentId: String?
    ) throws -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "userId", value: try requireUserId()),
            URLQueryItem(name: "includeItemTypes", value: includeTypes.joined(separator: ",")),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: query.sort.rawValue),
            URLQueryItem(name: "sortOrder", value: query.direction.rawValue),
            URLQueryItem(name: "limit", value: String(query.limit)),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        if let parentId { items.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let term = query.searchTerm, !term.isEmpty {
            items.append(URLQueryItem(name: "searchTerm", value: term))
        }
        // Pipe-delimited, unlike every other list Jellyfin takes: genre names contain
        // commas often enough ("Folk, World, & Country" is a real Discogs genre) that
        // a comma-separated list would split one genre into three that match nothing.
        if !query.genres.isEmpty {
            items.append(URLQueryItem(name: "genres", value: query.genres.joined(separator: "|")))
        }
        if !query.years.isEmpty {
            items.append(URLQueryItem(name: "years", value: query.years.map(String.init).joined(separator: ",")))
        }
        if query.favoritesOnly {
            items.append(URLQueryItem(name: "filters", value: "IsFavorite"))
        }
        return items
    }
}

extension MusicQuery {
    /// A short, readable account of what this query asks for.
    ///
    /// Shown above smart-search results so a wrong interpretation is visible rather
    /// than mysterious: "Jazz · 1990–1999" makes it obvious why a phrase about
    /// saxophones returned what it did, and gives the listener something to correct.
    public var summary: String {
        var parts: [String] = []
        if let searchTerm { parts.append("“\(searchTerm)”") }
        parts.append(contentsOf: genres)
        if let first = years.first, let last = years.last {
            parts.append(first == last ? "\(first)" : "\(first)–\(last)")
        }
        if favoritesOnly { parts.append("Favourites") }
        switch sort {
        case .releaseDate: parts.append("newest first")
        case .playCount: parts.append("most played")
        case .datePlayed: parts.append("recently played")
        case .random: parts.append("shuffled")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}
