import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Songs waiting in playlists")
struct PendingItemTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private let song = PendingSong(
        requestId: 12, title: "Paper Lanterns", artist: "The Quiet Hours",
        album: nil, durationMs: 383_000, why: nil
    )

    /// The contract's own example of a waiting item, as Melete writes it.
    private func waitingPayload(id: String = "item-1", updatedAt: Int64 = 2_000) -> JSONValue {
        .object([
            "id": .string(id), "playlistId": .string("list-1"), "position": .string("V"),
            "updatedAt": .int(updatedAt), "originDevice": .string("melete"), "deleted": .bool(false),
            "pending": .object([
                "requestId": .int(12), "title": .string("Paper Lanterns"), "artist": .string("The Quiet Hours"),
                "album": .null, "durationMs": .int(383_000), "why": .null,
            ]),
        ])
    }

    private func trackPayload(id: String = "item-1", updatedAt: Int64) -> JSONValue {
        .object([
            "id": .string(id), "playlistId": .string("list-1"), "position": .string("V"),
            "updatedAt": .int(updatedAt), "originDevice": .string("melete"), "deleted": .bool(false),
            "jellyfinId": .string("2"), "contentKey": .string("the quiet hours|night|paper lanterns|383"),
        ])
    }

    private func stored(_ store: CurationStore, _ id: String = "item-1") throws -> PlaylistItem? {
        try store.read { try PlaylistItem.fetchOne($0, key: id) }
    }

    // MARK: - The wire

    @Test("a waiting item encodes with pending in place of the track, every field written")
    func encodesWaiting() throws {
        let item = PlaylistItem(id: "item-1", playlistId: "list-1", pending: song, position: "V",
                                updatedAt: 2_000, originDevice: "phone")
        let fields = try #require(try Wire.payload(item).objectValue)

        #expect(fields["jellyfinId"] == nil)
        #expect(fields["contentKey"] == nil)
        let pending = try #require(fields["pending"]?.objectValue)
        #expect(Set(pending.keys) == ["requestId", "title", "artist", "album", "durationMs", "why"])
        #expect(pending["requestId"] == .int(12))
        #expect(pending["album"] == .null)
        #expect(pending["why"] == .null)
    }

    @Test("a track's item encodes as it always did, with no pending")
    func encodesTrack() throws {
        let item = PlaylistItem(id: "item-1", playlistId: "list-1", jellyfinId: "2", contentKey: "k",
                                position: "V", updatedAt: 2_000, originDevice: "phone")
        let fields = try #require(try Wire.payload(item).objectValue)

        #expect(Set(fields.keys) == [
            "id", "playlistId", "jellyfinId", "contentKey", "position", "updatedAt", "deleted", "originDevice",
        ])
    }

    @Test("both shapes decode")
    func decodesBoth() throws {
        let decoder = JSONDecoder()
        let waiting = try decoder.decode(PlaylistItem.self, from: JSONEncoder().encode(waitingPayload()))
        #expect(waiting.isPending)
        #expect(waiting.jellyfinId == nil)
        #expect(waiting.pending == song)

        let track = try decoder.decode(PlaylistItem.self, from: JSONEncoder().encode(trackPayload(updatedAt: 3_000)))
        #expect(!track.isPending)
        #expect(track.jellyfinId == "2")
        #expect(track.pending == nil)
    }

    @Test("an unmatched song, asked for by nobody, keeps its reason")
    func decodesUnmatched() throws {
        var fields = try #require(waitingPayload().objectValue)
        fields["pending"] = .object([
            "requestId": .null, "title": .string("Xyzzy"), "artist": .null,
            "album": .null, "durationMs": .null, "why": .string("MusicBrainz has nothing that fits"),
        ])
        let item = try JSONDecoder().decode(PlaylistItem.self, from: JSONEncoder().encode(JSONValue.object(fields)))
        #expect(item.pending?.requestId == nil)
        #expect(item.pending?.why == "MusicBrainz has nothing that fits")
    }

    // MARK: - Merging

    @Test("a pulled waiting item is kept, not quarantined")
    func waitingItemIsKept() throws {
        let store = try store()
        let op = Wire.pulledRaw(entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                                payload: waitingPayload(), receivedAt: 2_000)
        let report = try store.applyOne(op)

        #expect(report.applied == 1)
        #expect(report.quarantinedInbound == 0)
        #expect(try store.quarantineCount() == 0)
        #expect(try stored(store)?.pending == song)
    }

    @Test("a waiting item later written with a track becomes an ordinary one")
    func arrivalSwapsTheTrackIn() throws {
        let store = try store()
        try store.applyOne(Wire.pulledRaw(entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                                          payload: waitingPayload(updatedAt: 2_000), seq: 1, receivedAt: 2_000))
        try store.applyOne(Wire.pulledRaw(entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                                          payload: trackPayload(updatedAt: 2_001), seq: 2, receivedAt: 2_001))

        let item = try #require(try stored(store))
        #expect(!item.isPending)
        #expect(item.pending == nil)
        #expect(item.jellyfinId == "2")
        #expect(item.position == "V")
        #expect(try store.quarantineCount() == 0)
    }

    @Test("an item with neither a track nor a pending song is still refused")
    func neitherIsRefused() throws {
        let store = try store()
        var fields = try #require(waitingPayload().objectValue)
        fields["pending"] = nil
        let op = Wire.pulledRaw(entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                                payload: .object(fields))
        #expect(try store.applyOne(op).quarantinedInbound == 1)
        #expect(try stored(store) == nil)
    }

    // MARK: - Writing one

    @Test("adding a waiting song appends it and queues its op")
    func addPendingSong() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Wish List", now: 1_000)
        try store.addTracks([TrackLink(jellyfinId: "1", contentKey: "k1")], to: list.id, now: 1_000)
        let added = try store.addPendingSong(song, to: list.id, now: 2_000)

        let items = try store.items(in: list.id)
        #expect(items.map(\.id).last == added.id)
        #expect(items.last?.pending == song)

        let op = try #require(try store.pendingOps().last)
        #expect(op.entityId == added.id)
        let fields = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(op.payload.utf8)).objectValue)
        #expect(fields["jellyfinId"] == nil)
        #expect(fields["pending"]?.objectValue?["requestId"] == .int(12))
        #expect(try store.itemCount(in: list.id) == 2)
    }

    @Test("relinking leaves a waiting song alone")
    func relinkSkipsWaiting() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Wish List", now: 1_000)
        try store.addPendingSong(song, to: list.id, now: 1_000)
        try store.writeLocal { db in
            try TrackRef(jellyfinId: "9", contentKey: "k9", title: "t", artist: "a", album: "b", lastSeenAt: 0).insert(db)
        }
        let opsBefore = try store.pendingOps().count

        let report = try store.relinkItemsAgainstTrackCache(now: 2_000)
        #expect(report.changed == 0)
        #expect(try store.pendingOps().count == opsBefore)
        #expect(try store.items(in: list.id).first?.isPending == true)
    }

    // MARK: - Data from before

    @Test("items stored before waiting songs existed load after the migration")
    func migrationKeepsItems() throws {
        let queue = try DatabaseQueue()
        try Schema.migrator.migrate(queue, upTo: "v10")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO playlistItem (id, playlistId, jellyfinId, contentKey, position, updatedAt, deleted, originDevice)
                VALUES ('old', 'list-1', '7', 'k7', 'V', 1000, 0, 'phone')
                """)
        }
        try Schema.migrator.migrate(queue)

        let item = try #require(try queue.read { try PlaylistItem.fetchOne($0, key: "old") })
        #expect(item.jellyfinId == "7")
        #expect(item.contentKey == "k7")
        #expect(item.pending == nil)
        try queue.write { db in
            try PlaylistItem(id: "new", playlistId: "list-1", pending: song, position: "W",
                             updatedAt: 2_000, originDevice: "phone").insert(db)
        }
        #expect(try queue.read { try PlaylistItem.fetchOne($0, key: "new") }?.pending == song)
    }

    @Test("waiting items an older build set aside are applied on the next sync")
    func replaysQuarantined() throws {
        let store = try store()
        try store.writeLocal { db in
            try QuarantinedOp(
                opId: "op-1", entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                direction: .inbound, reason: "undecodable", payload: try Wire.text(waitingPayload()),
                quarantinedAt: 2_500
            ).insert(db)
        }

        let report = try store.replayQuarantinedPendingItems(now: 3_000)
        #expect(report.applied == 1)
        #expect(try store.quarantineCount() == 0)
        #expect(try stored(store)?.pending == song)
        #expect(try store.pendingOps().isEmpty)
    }

    @Test("a set-aside waiting item loses to the track that has arrived since")
    func replayLosesToArrival() throws {
        let store = try store()
        try store.applyOne(Wire.pulledRaw(entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                                          payload: trackPayload(updatedAt: 2_001), receivedAt: 2_001))
        try store.writeLocal { db in
            try QuarantinedOp(
                opId: "op-1", entity: SyncEntity.playlistItem.wireName, entityId: "item-1",
                direction: .inbound, reason: "undecodable", payload: try Wire.text(waitingPayload()),
                quarantinedAt: 2_500
            ).insert(db)
        }

        try store.replayQuarantinedPendingItems(now: 3_000)
        #expect(try stored(store)?.jellyfinId == "2")
        #expect(try store.quarantineCount() == 0)
    }

    @Test("other quarantined ops stay where they are")
    func replayLeavesOthers() throws {
        let store = try store()
        try store.writeLocal { db in
            try QuarantinedOp(
                opId: "op-2", entity: SyncEntity.playlistItem.wireName, entityId: "item-2",
                direction: .inbound, reason: "undecodable", payload: #"{"id":"item-2"}"#,
                quarantinedAt: 2_500
            ).insert(db)
        }
        try store.replayQuarantinedPendingItems(now: 3_000)
        #expect(try store.quarantineCount() == 1)
    }
}
