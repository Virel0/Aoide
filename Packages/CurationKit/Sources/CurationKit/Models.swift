import Foundation
import GRDB

/// Milliseconds since the epoch — the timestamp every syncable row carries.
public typealias Millis = Int64

public extension Date {
    var millis: Millis { Millis(timeIntervalSince1970 * 1000) }
}

/// The four columns every syncable row carries.
///
/// `deleted` is a flag rather than a `DELETE` because a removed row has to be
/// *transmissible*: the absence of a row is indistinguishable from never having
/// seen it, so a hard delete would resurrect itself from any device that still had
/// a copy.
public protocol Syncable {
    var id: String { get }
    var updatedAt: Millis { get set }
    var deleted: Bool { get set }
    var originDevice: String { get set }
}

// MARK: - Track cache

public struct TrackRef: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "track"

    public var jellyfinId: String
    public var contentKey: String
    public var musicbrainzId: String?
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    /// The album's own id, for drawing a playlist cover from what it holds.
    public var albumId: String?
    public var durationMs: Int?
    public var year: Int?
    /// JSON array. Stored as text because SQLite has no array type and a join table
    /// for something only ever read whole would be ceremony.
    public var genres: String
    public var lastSeenAt: Millis

    public init(
        jellyfinId: String,
        contentKey: String,
        musicbrainzId: String? = nil,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        albumId: String? = nil,
        durationMs: Int? = nil,
        year: Int? = nil,
        genres: [String] = [],
        lastSeenAt: Millis
    ) {
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
        self.musicbrainzId = musicbrainzId
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.albumId = albumId
        self.durationMs = durationMs
        self.year = year
        self.genres = (try? String(data: JSONEncoder().encode(genres), encoding: .utf8)) ?? "[]"
        self.lastSeenAt = lastSeenAt
    }

    public var genreList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(genres.utf8))) ?? []
    }
}

/// The fingerprint that survives a Jellyfin rescan.
///
/// Normalised hard, because the point is to match the *same recording* after its id
/// changed — not to be a checksum. Duration is rounded to the second so a re-encode
/// that shifts it by a few milliseconds still matches.
public enum ContentKey {
    public static func make(artist: String, album: String, title: String, durationMs: Int?) -> String {
        let seconds = durationMs.map { Int(($0 + 500) / 1000) } ?? 0
        let parts = [normalise(artist), normalise(album), normalise(title), String(seconds)]
        return parts.joined(separator: "|")
    }

    private static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }
}

// MARK: - Curation

public struct Folder: Codable, FetchableRecord, PersistableRecord, Syncable, FieldStamped, Hashable, Sendable {
    public static let databaseTableName = "folder"

    public var id: String
    public var name: String
    public var parentId: String?
    public var sortIndex: String
    public var updatedAt: Millis
    public var deleted: Bool
    public var originDevice: String
    /// When each field last changed. `nil` on rows written before per-field merging.
    public var fieldUpdatedAt: FieldStamps?

    public init(
        id: String = UUID().uuidString,
        name: String,
        parentId: String? = nil,
        sortIndex: String,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String,
        fieldUpdatedAt: FieldStamps? = nil
    ) {
        self.id = id
        self.name = name
        self.parentId = parentId
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
        self.fieldUpdatedAt = fieldUpdatedAt
    }
}

public struct Playlist: Codable, FetchableRecord, PersistableRecord, Syncable, FieldStamped, Hashable, Sendable {
    public static let databaseTableName = "playlist"

    public var id: String
    public var name: String
    public var notes: String?
    public var folderId: String?
    public var isSmart: Bool
    /// JSON rule set; nil unless `isSmart`.
    public var smartRules: String?
    public var sortIndex: String
    public var updatedAt: Millis
    public var deleted: Bool
    public var originDevice: String
    /// When each field last changed. `nil` on rows written before per-field merging.
    public var fieldUpdatedAt: FieldStamps?
    /// The Jellyfin playlist this was imported from, if it was.
    public var sourceJellyfinId: String?
    /// A Jellyfin item whose cover stands in for this playlist's. `nil` means one is
    /// drawn from the playlist's own albums instead.
    public var artworkItemId: String?
    /// SHA-256 of a cover uploaded for this playlist, when one was chosen from
    /// outside the library. Beats `artworkItemId`; the bytes live behind the hash.
    public var imageHash: String?
    public var imageMime: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        notes: String? = nil,
        folderId: String? = nil,
        isSmart: Bool = false,
        smartRules: String? = nil,
        sortIndex: String,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String,
        fieldUpdatedAt: FieldStamps? = nil,
        sourceJellyfinId: String? = nil,
        artworkItemId: String? = nil,
        imageHash: String? = nil,
        imageMime: String? = nil
    ) {
        self.id = id
        self.name = name
        self.notes = notes
        self.folderId = folderId
        self.isSmart = isSmart
        self.smartRules = smartRules
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
        self.fieldUpdatedAt = fieldUpdatedAt
        self.sourceJellyfinId = sourceJellyfinId
        self.artworkItemId = artworkItemId
        self.imageHash = imageHash
        self.imageMime = imageMime
    }
}

public struct PlaylistItem: Codable, FetchableRecord, PersistableRecord, Syncable, Hashable, Sendable {
    public static let databaseTableName = "playlistItem"

    public var id: String
    public var playlistId: String
    public var jellyfinId: String
    public var contentKey: String
    /// A `FractionalIndex`, not an integer — see that type for why.
    public var position: String
    public var updatedAt: Millis
    public var deleted: Bool
    public var originDevice: String

    public init(
        id: String = UUID().uuidString,
        playlistId: String,
        jellyfinId: String,
        contentKey: String,
        position: String,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String
    ) {
        self.id = id
        self.playlistId = playlistId
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
        self.position = position
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
    }
}

public struct Like: Codable, FetchableRecord, PersistableRecord, Syncable, Hashable, Sendable {
    public static let databaseTableName = "like"

    public var id: String
    public var jellyfinId: String
    public var contentKey: String
    public var liked: Bool
    public var updatedAt: Millis
    public var deleted: Bool
    public var originDevice: String

    public init(
        id: String = UUID().uuidString,
        jellyfinId: String,
        contentKey: String,
        liked: Bool,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
        self.liked = liked
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
    }
}

// MARK: - Taste flags

/// What a listener has said about a track beyond liking it: "never offer this to
/// me", and "a play of this is not a fact about my taste".
///
/// Its own row rather than fields on `Like`, because a like set on one device and
/// a flag set on another at the same moment must both survive — `Like` merges
/// whole-row, and this merges per field, like a playlist. One row per track; the
/// unique index on `jellyfinId` is what the merge dedupes on.
public struct TrackFlags: Codable, FetchableRecord, PersistableRecord, Syncable, FieldStamped, Hashable, Sendable {
    public static let databaseTableName = "trackFlags"

    public var id: String
    public var jellyfinId: String
    public var contentKey: String
    /// Excluded from mixes, stations, smart-playlist results and shuffle. Still
    /// playable, still in ordinary playlists.
    public var notInterested: Bool
    /// New plays are not recorded. Existing history — including a play another
    /// device recorded before it saw this flag — is untouched; evaluation reads the
    /// flag rather than trusting the events never to have existed.
    public var dontCount: Bool
    public var updatedAt: Millis
    public var deleted: Bool
    public var originDevice: String
    public var fieldUpdatedAt: FieldStamps?

    public init(
        id: String = UUID().uuidString,
        jellyfinId: String,
        contentKey: String,
        notInterested: Bool = false,
        dontCount: Bool = false,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String,
        fieldUpdatedAt: FieldStamps? = nil
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
        self.notInterested = notInterested
        self.dontCount = dontCount
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
        self.fieldUpdatedAt = fieldUpdatedAt
    }

    /// A row with neither flag set says nothing; it is deleted rather than kept.
    public var isEmpty: Bool { !notInterested && !dontCount }
}

// MARK: - History

/// Where a play was started from, so recaps can say "mostly from playlists" and
/// weighted shuffle can avoid over-counting a track it chose itself.
public enum PlaySource: String, Codable, Sendable {
    case album, playlist, shuffle, search, siri, carplay, smart, unknown
}

public struct PlayEvent: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "playEvent"

    public var id: String
    public var jellyfinId: String
    public var contentKey: String
    public var startedAt: Millis
    public var endedAt: Millis?
    public var msPlayed: Int
    /// The track reached its end rather than being skipped away from.
    public var completed: Bool
    public var skipped: Bool
    public var source: String?
    /// What the listener was doing when this began. See ``Activity``.
    public var activity: String?
    public var originDevice: String

    public init(
        id: String = UUID().uuidString,
        jellyfinId: String,
        contentKey: String,
        startedAt: Millis,
        endedAt: Millis? = nil,
        msPlayed: Int = 0,
        completed: Bool = false,
        skipped: Bool = false,
        source: PlaySource = .unknown,
        activity: Activity? = nil,
        originDevice: String
    ) {
        self.id = id
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.msPlayed = msPlayed
        self.completed = completed
        self.skipped = skipped
        self.source = source.rawValue
        self.activity = activity?.rawValue
        self.originDevice = originDevice
    }
}

public struct QueueState: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "queueState"

    public var deviceId: String
    public var deviceName: String
    /// JSON array of Jellyfin ids.
    public var trackIds: String
    public var position: Int
    public var elapsedMs: Int
    public var updatedAt: Millis
    public var originDevice: String

    public init(
        deviceId: String,
        deviceName: String,
        trackIds: [String],
        position: Int,
        elapsedMs: Int,
        updatedAt: Millis
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.trackIds = (try? String(data: JSONEncoder().encode(trackIds), encoding: .utf8)) ?? "[]"
        self.position = position
        self.elapsedMs = elapsedMs
        self.updatedAt = updatedAt
        self.originDevice = deviceId
    }

    public var trackIdList: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(trackIds.utf8))) ?? []
    }
}

// MARK: - Sync

public struct Op: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "op"

    public enum Kind: String, Codable, Sendable { case upsert, delete }

    public var opId: String
    public var entity: String
    public var entityId: String
    public var operation: String
    public var payload: String
    public var createdAt: Millis
    public var synced: Bool

    public init(
        opId: String = UUID().uuidString,
        entity: String,
        entityId: String,
        operation: Kind,
        payload: String,
        createdAt: Millis,
        synced: Bool = false
    ) {
        self.opId = opId
        self.entity = entity
        self.entityId = entityId
        self.operation = operation.rawValue
        self.payload = payload
        self.createdAt = createdAt
        self.synced = synced
    }
}
