import Foundation

/// The kinds of item the app lists.
public enum ItemKind: String, Codable, Sendable {
    case audio
    case musicAlbum
    case musicArtist
    /// A genre. Melete names genres rather than numbering them, so its id is its
    /// name.
    case musicGenre
    /// An Aoide playlist, as `/api/v1/playlists` lists it.
    case playlist
    case unknown
}

/// A track, album, artist, genre or playlist, in the one shape the app's lists
/// draw. Built from Melete's own types (`MusicTrack`, `MusicAlbum`, …), each
/// filling in what it has.
///
/// `Codable` in its own shape, for what the app keeps on disk (the downloads'
/// list); Melete's answers are read through the `Wire…` types instead.
public struct MusicItem: Codable, Hashable, Identifiable, Sendable {
    /// The server's id, as text (Melete's ids are numbers).
    public let id: String
    public let name: String
    public let type: ItemKind

    /// A track's album's id; an album's own.
    public var albumId: String?
    public var album: String?
    public var albumArtist: String?
    /// The album artist's id, when there is one artist to name.
    public var albumArtistId: String?
    /// A track's artists in credit order (a featured artist after the main one).
    public var artists: [String]
    public var artistItems: [NameIdPair]
    public var genres: [String]

    public var trackNumber: Int?
    public var discNumber: Int?
    public var year: Int?
    /// An album's tracks, an artist's albums, a genre's or playlist's tracks.
    public var childCount: Int?
    public var duration: Duration?

    /// Whether the album has a cover: always assumed for a track, whose album may
    /// or may not (Melete doesn't say on the track).
    public var hasCover: Bool
    /// Whether the signed-in user likes the track, as their sync log says.
    public var liked: Bool
    public var isrc: String?

    public init(
        id: String,
        name: String,
        type: ItemKind,
        albumId: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        albumArtistId: String? = nil,
        artists: [String] = [],
        artistItems: [NameIdPair] = [],
        genres: [String] = [],
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        childCount: Int? = nil,
        duration: Duration? = nil,
        hasCover: Bool = false,
        liked: Bool = false,
        isrc: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.albumId = albumId
        self.album = album
        self.albumArtist = albumArtist
        self.albumArtistId = albumArtistId
        self.artists = artists
        self.artistItems = artistItems
        self.genres = genres
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.year = year
        self.childCount = childCount
        self.duration = duration
        self.hasCover = hasCover
        self.liked = liked
        self.isrc = isrc
    }

    /// The length in whole milliseconds, as the local store keeps it.
    public var durationMs: Int? {
        duration.map { Int($0.components.seconds) * 1000 + Int($0.components.attoseconds / 1_000_000_000_000_000) }
    }

    /// The album whose cover stands for this item: an album's own, a track's
    /// album's. Artists, genres and playlists have none here.
    public var coverAlbumId: String? {
        switch type {
        case .audio, .musicAlbum: hasCover ? albumId : nil
        default: nil
        }
    }

    public var subtitle: String {
        switch type {
        case .audio: albumArtist ?? artists.first ?? ""
        case .musicAlbum: albumArtist ?? artists.first ?? ""
        case .musicArtist: ""
        case .playlist: childCount.map { "\($0) songs" } ?? ""
        default: ""
        }
    }
}

public struct NameIdPair: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One page of a list, and how many there are in all.
public struct ItemsResponse: Sendable {
    public let items: [MusicItem]
    public let totalRecordCount: Int
    public let startIndex: Int

    public static let empty = ItemsResponse(items: [], totalRecordCount: 0, startIndex: 0)

    public init(items: [MusicItem], totalRecordCount: Int, startIndex: Int) {
        self.items = items
        self.totalRecordCount = totalRecordCount
        self.startIndex = startIndex
    }
}

// MARK: - Melete's answers

/// Melete's paged envelope, `{"items", "total"}`.
struct WirePage<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int
}

/// A length in seconds, as Melete sends it; negative or missing is unknown.
private func seconds(_ value: Double?) -> Duration? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return .milliseconds(Int64((value * 1000).rounded()))
}

/// `MusicTrack`, trimmed to what the app shows.
struct WireTrack: Decodable {
    struct Credit: Decodable {
        let id: Int64
        let name: String
    }
    let id: Int64
    let title: String
    let albumId: Int64
    let album: String
    let albumArtist: String
    let trackNumber: Int?
    let discNumber: Int?
    let year: Int?
    let durationSeconds: Double?
    let genres: [String]?
    let codec: String?
    let bitrateKbps: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let isrc: String?
    let liked: Bool?
    let artists: [Credit]?

    var item: MusicItem {
        let credits = (artists ?? []).map { NameIdPair(id: String($0.id), name: $0.name) }
        return MusicItem(
            id: String(id),
            name: title,
            type: .audio,
            albumId: String(albumId),
            album: album,
            albumArtist: albumArtist,
            artists: credits.map(\.name),
            artistItems: credits,
            genres: genres ?? [],
            trackNumber: trackNumber,
            discNumber: discNumber,
            year: year,
            duration: seconds(durationSeconds),
            hasCover: true,
            liked: liked ?? false,
            isrc: isrc
        )
    }
}

/// `MusicAlbum`, trimmed.
struct WireAlbum: Decodable {
    let id: Int64
    let title: String
    let artistId: Int64?
    let artist: String
    let year: Int?
    let tracks: Int
    let durationSeconds: Double?
    let cover: String?
    let genres: [String]?
    /// On an album's own page only, from servers that have album likes.
    let liked: Bool?

    var item: MusicItem {
        MusicItem(
            id: String(id),
            name: title,
            type: .musicAlbum,
            albumId: String(id),
            albumArtist: artist,
            albumArtistId: artistId.map(String.init),
            genres: genres ?? [],
            year: year,
            childCount: tracks,
            duration: seconds(durationSeconds),
            hasCover: cover != nil,
            liked: liked ?? false
        )
    }
}

/// `MusicArtist`, trimmed.
struct WireArtist: Decodable {
    let id: Int64
    let name: String
    let albums: Int

    var item: MusicItem {
        MusicItem(id: String(id), name: name, type: .musicArtist, childCount: albums)
    }
}

/// `MusicGenre`.
struct WireGenre: Decodable {
    let name: String
    let tracks: Int

    var item: MusicItem {
        MusicItem(id: name, name: name, type: .musicGenre, childCount: tracks)
    }
}
