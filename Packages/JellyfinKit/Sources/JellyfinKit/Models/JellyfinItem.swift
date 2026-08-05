import Foundation

/// The kinds of `BaseItemDto` this app cares about. Jellyfin serves dozens more
/// (movies, episodes, books); anything we don't model decodes as `.unknown`
/// rather than failing the whole response.
public enum ItemKind: String, Codable, Sendable {
    case audio = "Audio"
    case musicAlbum = "MusicAlbum"
    case musicArtist = "MusicArtist"
    case musicGenre = "MusicGenre"
    case playlist = "Playlist"
    case collectionFolder = "CollectionFolder"
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ItemKind(rawValue: raw) ?? .unknown
    }
}

/// Per-user state Jellyfin attaches to an item.
public struct UserItemData: Codable, Hashable, Sendable {
    public var isFavorite: Bool
    public var played: Bool
    public var playCount: Int
    public var playbackPositionTicks: Int64

    public init(
        isFavorite: Bool = false,
        played: Bool = false,
        playCount: Int = 0,
        playbackPositionTicks: Int64 = 0
    ) {
        self.isFavorite = isFavorite
        self.played = played
        self.playCount = playCount
        self.playbackPositionTicks = playbackPositionTicks
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        playbackPositionTicks = try c.decodeIfPresent(Int64.self, forKey: .playbackPositionTicks) ?? 0
    }
}

/// A trimmed `BaseItemDto`. Jellyfin's real DTO has ~200 fields; decoding only what
/// we render keeps parsing cheap on large libraries and keeps this type reviewable.
public struct JellyfinItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: ItemKind

    public var albumId: String?
    public var album: String?
    public var albumArtist: String?
    public var artists: [String]
    public var artistItems: [NameIdPair]
    public var genres: [String]

    /// Track number within its disc.
    public var indexNumber: Int?
    /// Disc number within its album.
    public var parentIndexNumber: Int?
    public var productionYear: Int?
    public var childCount: Int?
    /// Only present on `collectionFolder` items — `"music"` marks a music library.
    public var collectionType: String?

    /// Jellyfin measures duration in 100-nanosecond ticks.
    public var runTimeTicks: Int64?

    /// Image tags double as cache keys — the tag changes when the artwork changes.
    public var imageTags: [String: String]
    public var albumPrimaryImageTag: String?
    public var userData: UserItemData?

    public var duration: Duration? {
        guard let runTimeTicks else { return nil }
        return .nanoseconds(runTimeTicks * 100)
    }

    /// The item whose artwork represents this one. Tracks usually carry no artwork
    /// of their own and borrow the album's.
    public var artworkSource: (itemId: String, tag: String)? {
        if let tag = imageTags["Primary"] { return (id, tag) }
        if let tag = albumPrimaryImageTag, let albumId { return (albumId, tag) }
        return nil
    }

    /// What Apple Music would show as the subtitle line.
    public var subtitle: String {
        switch type {
        case .audio: albumArtist ?? artists.first ?? ""
        case .musicAlbum: albumArtist ?? artists.first ?? ""
        case .musicArtist: ""
        case .playlist: childCount.map { "\($0) songs" } ?? ""
        default: ""
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try c.decodeIfPresent(ItemKind.self, forKey: .type) ?? .unknown
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        artists = try c.decodeIfPresent([String].self, forKey: .artists) ?? []
        artistItems = try c.decodeIfPresent([NameIdPair].self, forKey: .artistItems) ?? []
        genres = try c.decodeIfPresent([String].self, forKey: .genres) ?? []
        indexNumber = try c.decodeIfPresent(Int.self, forKey: .indexNumber)
        parentIndexNumber = try c.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        productionYear = try c.decodeIfPresent(Int.self, forKey: .productionYear)
        childCount = try c.decodeIfPresent(Int.self, forKey: .childCount)
        collectionType = try c.decodeIfPresent(String.self, forKey: .collectionType)
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        imageTags = try c.decodeIfPresent([String: String].self, forKey: .imageTags) ?? [:]
        albumPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)
        userData = try c.decodeIfPresent(UserItemData.self, forKey: .userData)
    }
}

public struct NameIdPair: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    }
}

/// Jellyfin's standard paged envelope.
public struct ItemsResponse: Codable, Sendable {
    public let items: [JellyfinItem]
    public let totalRecordCount: Int
    public let startIndex: Int

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([JellyfinItem].self, forKey: .items) ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount) ?? 0
        startIndex = try c.decodeIfPresent(Int.self, forKey: .startIndex) ?? 0
    }
}
