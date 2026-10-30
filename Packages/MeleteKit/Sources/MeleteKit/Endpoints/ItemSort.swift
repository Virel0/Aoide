import Foundation

/// Sort orders, named for how the UI describes them. Melete sorts tracks by
/// album order, title or newest; albums by artist, title, year or newest; and
/// chooses the direction itself. The orders it has no sort for (play counts,
/// last played, shuffled) are the server's default order here: callers that
/// need them put the list in order themselves.
public enum ItemSort: String, Sendable, CaseIterable, Identifiable {
    case name
    case dateAdded
    case datePlayed
    case playCount
    case artist
    case releaseDate
    case random
    case albumTrackOrder

    public var id: Self { self }

    /// The sorts a browse screen offers: the ones Melete can do.
    public static var browsable: [ItemSort] { [.name, .artist, .dateAdded, .releaseDate] }

    public var displayName: String {
        switch self {
        case .name: "Title"
        case .artist: "Artist"
        case .dateAdded: "Recently Added"
        case .datePlayed: "Recently Played"
        case .playCount: "Most Played"
        case .releaseDate: "Release Date"
        case .random: "Shuffle Order"
        case .albumTrackOrder: "Track Order"
        }
    }

    public var naturalDirection: SortDirection {
        switch self {
        case .dateAdded, .datePlayed, .playCount, .releaseDate: .descending
        default: .ascending
        }
    }

    /// The `sort` value for tracks, if this order applies to them.
    var forTracks: String? {
        switch self {
        case .name: "title"
        case .dateAdded: "recent"
        default: nil
        }
    }

    /// The `sort` value for albums.
    var forAlbums: String? {
        switch self {
        case .name: "title"
        case .artist: "artist"
        case .dateAdded: "recent"
        case .releaseDate: "year"
        default: nil
        }
    }
}

public enum SortDirection: String, Sendable {
    case ascending
    case descending
}
