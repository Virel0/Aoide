import Foundation

/// A collection: songs saved on Melete's web as a filter (several genres, a span
/// of years, only the songs the listener likes), named. It holds no songs, only
/// the filter, so its songs are always what the library has now. Each listener's
/// are their own.
public struct SongCollection: Decodable, Hashable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let genres: [String]
    public let yearFrom: Int?
    public let yearTo: Int?
    public let liked: Bool

    public init(id: Int64, name: String, genres: [String] = [], yearFrom: Int? = nil, yearTo: Int? = nil, liked: Bool = false) {
        self.id = id
        self.name = name
        self.genres = genres
        self.yearFrom = yearFrom
        self.yearTo = yearTo
        self.liked = liked
    }

    /// The filter as `/music/tracks` takes it: genres separated by semicolons,
    /// either year, `liked`; what isn't set is left out.
    public var filters: [URLQueryItem] {
        var query: [URLQueryItem] = []
        if !genres.isEmpty { query.append(URLQueryItem(name: "genres", value: genres.joined(separator: ";"))) }
        if let yearFrom { query.append(URLQueryItem(name: "year_from", value: String(yearFrom))) }
        if let yearTo { query.append(URLQueryItem(name: "year_to", value: String(yearTo))) }
        if liked { query.append(URLQueryItem(name: "liked", value: "true")) }
        return query
    }

    /// What it holds, in a line: "Jazz, Soul · 1960–1969 · Liked songs".
    public var summary: String {
        var parts: [String] = []
        if !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        switch (yearFrom, yearTo) {
        case let (from?, to?): parts.append(from == to ? "\(from)" : "\(from)–\(to)")
        case let (from?, nil): parts.append("From \(from)")
        case let (nil, to?): parts.append("Up to \(to)")
        case (nil, nil): break
        }
        if liked { parts.append("Liked songs") }
        return parts.joined(separator: " · ")
    }
}
