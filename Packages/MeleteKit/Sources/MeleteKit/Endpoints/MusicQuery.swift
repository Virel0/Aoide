import Foundation

/// A library query assembled from parts rather than a single search string.
///
/// Melete's `q` matches titles and names and nothing else, so "upbeat rock from
/// the nineties" as a search term matches nothing at all — no track is called that.
/// The parts here map onto what the server can narrow by (words, a genre), and the
/// rest (several genres, years, likes, orders it has no sort for) is applied here
/// to what it sends: something else turns the words into this, and the server's
/// library still does the choosing.
public struct MusicQuery: Sendable, Equatable {
    /// Words to match against names. Only set when the phrase actually named a
    /// title or performer.
    public var searchTerm: String?
    /// Genre *names*, which is what Melete's `genre` filter takes (one a request).
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
    /// The years are a list of exact ones, not a range. Anything this wide is not
    /// really a date filter, so it's dropped rather than truncated — truncating
    /// would silently answer a different question.
    static let maxYearSpan = 40

    /// Expands an inclusive range into the list of years a query keeps.
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

extension MeleteClient {
    /// The songs a query matches, at most `query.limit`.
    public func songs(matching query: MusicQuery) async throws -> [MusicItem] {
        try await matching(query, WireTrack.self, "tracks", sort: query.sort.forTracks, liked: { $0.liked })
    }

    /// The albums a query matches, at most `query.limit`; with `favoritesOnly`, the
    /// albums of the songs the listener likes.
    public func albums(matching query: MusicQuery) async throws -> [MusicItem] {
        var likedAlbums: Set<String> = []
        if query.favoritesOnly {
            likedAlbums = Set(try await likedTracks().compactMap(\.albumId))
        }
        return try await matching(query, WireAlbum.self, "albums", sort: query.sort.forAlbums) {
            likedAlbums.contains($0.id)
        }
    }

    /// One request per genre (one for every genre when none is named), each read
    /// whole when anything is narrowed here; then the years and likes, the order,
    /// and the limit.
    private func matching<Wire: Decodable & ItemWire>(
        _ query: MusicQuery,
        _ wire: Wire.Type,
        _ list: String,
        sort: String?,
        liked: (MusicItem) -> Bool
    ) async throws -> [MusicItem] {
        let narrowsHere = !query.years.isEmpty || query.favoritesOnly || query.genres.count > 1
            || query.sort == .releaseDate || query.sort == .random
        var words: [URLQueryItem] = []
        if let term = query.searchTerm, !term.isEmpty {
            words += list == "tracks" ? Self.songWords(term) : [URLQueryItem(name: "q", value: term)]
        }
        let genres: [String?] = query.genres.isEmpty ? [nil] : query.genres
        var found: [MusicItem] = []
        var seen = Set<String>()
        for genre in genres {
            let filters = words + (genre.map { [URLQueryItem(name: "genre", value: $0)] } ?? [])
            let page = try await self.list(
                wire, list, filters: filters, sort: sort,
                limit: narrowsHere ? nil : query.limit
            ) { $0.item }
            found += page.items.filter { seen.insert($0.id).inserted }
        }
        found = found.filter { item in
            (query.years.isEmpty || item.year.map(query.years.contains) == true)
                && (!query.favoritesOnly || liked(item))
        }
        switch query.sort {
        case .releaseDate: found.sort { ($0.year ?? .min) > ($1.year ?? .min) }
        case .random: found.shuffle()
        default: break
        }
        return Array(found.prefix(query.limit))
    }
}

/// Melete's answer types that become items.
protocol ItemWire { var item: MusicItem { get } }
extension WireTrack: ItemWire {}
extension WireAlbum: ItemWire {}

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
