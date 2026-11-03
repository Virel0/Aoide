import Foundation
import GRDB

/// A song a playlist holds before the library does, as the sync log carries it.
///
/// It stands in a `playlist_items` payload in place of `jellyfinId` and
/// `contentKey`. Every field is written, `null` when unknown, as Melete writes them.
/// `requestId` is the song request that will bring it; `nil` when nothing could be
/// asked for, and `why` then says why and it stays waiting. Once the song arrives,
/// Melete writes the same item again with the track in place of this, and the
/// ordinary merge takes it.
public struct PendingSong: Codable, Hashable, Sendable {
    public var requestId: Int64?
    public var title: String
    /// Its artists, comma-separated.
    public var artist: String?
    public var album: String?
    public var durationMs: Int?
    public var why: String?

    public init(
        requestId: Int64?,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        durationMs: Int? = nil,
        why: String? = nil
    ) {
        self.requestId = requestId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.why = why
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, title, artist, album, durationMs, why
    }

    /// Nulls written out rather than left out, as the contract asks.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestId, forKey: .requestId)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(why, forKey: .why)
    }
}

public extension PlaylistItem {
    /// An entry for a song the library doesn't have yet.
    init(
        id: String = UUID().uuidString,
        playlistId: String,
        pending: PendingSong,
        position: String,
        updatedAt: Millis,
        deleted: Bool = false,
        originDevice: String
    ) {
        self.id = id
        self.playlistId = playlistId
        self.jellyfinId = nil
        self.contentKey = nil
        self.pending = pending
        self.position = position
        self.updatedAt = updatedAt
        self.deleted = deleted
        self.originDevice = originDevice
    }
}

public extension CurationStore {
    /// Appends a song the library doesn't have yet to the end of a playlist.
    @discardableResult
    func addPendingSong(
        _ song: PendingSong,
        to playlistId: String,
        now: Millis = Date().millis
    ) throws -> PlaylistItem {
        guard try playlist(playlistId) != nil else { throw PlaylistError.noSuchPlaylist(playlistId) }
        let last = try items(in: playlistId).last?.position
        return try record(
            PlaylistItem(
                playlistId: playlistId,
                pending: song,
                position: FractionalIndex.between(last, nil),
                updatedAt: now,
                originDevice: deviceId
            ),
            at: now
        )
    }

    /// Applies the waiting songs a build before this one set aside.
    ///
    /// A build that didn't know `pending` found an item with no track id and
    /// quarantined it, and the pull cursor has moved past it since, so the server
    /// won't offer it again: the quarantined copy is the only one. Each goes through
    /// the ordinary merge, so a newer copy already here (the track Melete swapped in)
    /// still wins, and leaves quarantine unless it is refused again.
    @discardableResult
    func replayQuarantinedPendingItems(now: Millis = Date().millis) throws -> SyncReport {
        try writeLocal { db in
            let held = try QuarantinedOp
                .filter(Column("direction") == SyncDirection.inbound.rawValue)
                .filter(Column("entity") == SyncEntity.playlistItem.wireName)
                .fetchAll(db)
            var applier = InboundApplier(policy: .default, now: now)
            for row in held {
                guard let op = Self.pulledOp(replaying: row) else { continue }
                let refusedBefore = applier.report.quarantinedInbound
                try applier.apply(op, in: db)
                if applier.report.quarantinedInbound == refusedBefore {
                    _ = try QuarantinedOp.deleteOne(db, key: row.opId)
                }
            }
            return applier.report
        }
    }

    /// The pulled op a quarantined waiting item came in as, near enough to merge: its
    /// own payload, timed by its own `updatedAt` and received when it was set aside.
    /// `nil` for anything that isn't a waiting item.
    private static func pulledOp(replaying row: QuarantinedOp) -> PulledOp? {
        guard let payload = try? JSONDecoder().decode(JSONValue.self, from: Data(row.payload.utf8)),
              let fields = payload.objectValue,
              fields["pending"]?.objectValue != nil
        else { return nil }
        let updatedAt = if case .int(let value)? = fields["updatedAt"] { value } else { row.quarantinedAt }
        return PulledOp(
            opId: row.opId,
            entity: row.entity,
            entityId: row.entityId,
            operation: fields["deleted"]?.isFlagSet == true ? Op.Kind.delete.rawValue : Op.Kind.upsert.rawValue,
            payload: payload,
            createdAt: updatedAt,
            seq: 0,
            deviceId: fields["originDevice"]?.stringValue ?? "",
            receivedAt: row.quarantinedAt
        )
    }
}
