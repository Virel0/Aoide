import Foundation
import Testing
@testable import CurationKit

@Suite("Sync entity names")
struct SyncEntityTests {
    /// The bug this mapping exists for. Ops in the database name GRDB tables; the
    /// server's allow-list names its own. Every op already stored would be rejected
    /// without the translation, so the six strings are pinned here literally — a
    /// test that derived them from the enum would agree with any typo.
    @Test("wire names are the server's allow-list, exactly")
    func wireNames() {
        #expect(SyncEntity.playlist.wireName == "playlists")
        #expect(SyncEntity.playlistItem.wireName == "playlist_items")
        #expect(SyncEntity.folder.wireName == "folders")
        #expect(SyncEntity.like.wireName == "likes")
        #expect(SyncEntity.playEvent.wireName == "play_events")
        #expect(SyncEntity.queueState.wireName == "queue_state")
    }

    /// The other half of the same bug: a table renamed in the schema without the
    /// mapping following would send ops the server has never heard of.
    @Test("local names are the record types' table names")
    func localNames() {
        #expect(SyncEntity.playlist.localTable == Playlist.databaseTableName)
        #expect(SyncEntity.playlistItem.localTable == PlaylistItem.databaseTableName)
        #expect(SyncEntity.folder.localTable == Folder.databaseTableName)
        #expect(SyncEntity.like.localTable == Like.databaseTableName)
        #expect(SyncEntity.playEvent.localTable == PlayEvent.databaseTableName)
        #expect(SyncEntity.queueState.localTable == QueueState.databaseTableName)
    }

    @Test("every entity survives the round trip both ways")
    func roundTrip() {
        for entity in SyncEntity.allCases {
            #expect(SyncEntity(wireName: entity.wireName) == entity)
            #expect(SyncEntity(localTable: entity.localTable) == entity)
        }
    }

    @Test("no two entities share a name")
    func namesAreDistinct() {
        #expect(Set(SyncEntity.allCases.map(\.wireName)).count == SyncEntity.allCases.count)
        #expect(Set(SyncEntity.allCases.map(\.localTable)).count == SyncEntity.allCases.count)
    }

    /// The track cache is per-device and the server refuses it. There is no enum
    /// case for it, so it cannot be named — which is the enforcement.
    @Test("the track cache cannot be named at all")
    func trackIsUnnameable() {
        #expect(SyncEntity(localTable: TrackRef.databaseTableName) == nil)
        #expect(SyncEntity(wireName: "tracks") == nil)
        #expect(SyncEntity(wireName: "track") == nil)
    }

    /// A newer client syncing an entity this build has never heard of must be
    /// quarantined, not crashed on.
    @Test("an unknown name is nil rather than a trap")
    func unknownNames() {
        #expect(SyncEntity(wireName: "downloads") == nil)
        #expect(SyncEntity(localTable: "download") == nil)
        #expect(SyncEntity(wireName: "") == nil)
        // The allow-list is case-sensitive on the server, so it is here too.
        #expect(SyncEntity(wireName: "Playlists") == nil)
    }

    @Test("queue state is identified by its device, everything else by its id")
    func identityKeys() {
        #expect(SyncEntity.queueState.identityKey == "deviceId")
        for entity in SyncEntity.allCases where entity != .queueState {
            #expect(entity.identityKey == "id")
        }
    }

    @Test("only play events are append-only")
    func appendOnly() {
        #expect(SyncEntity.playEvent.isAppendOnly)
        for entity in SyncEntity.allCases where entity != .playEvent {
            #expect(!entity.isAppendOnly)
        }
    }

    /// The end-to-end version: what the store actually writes has to be a name the
    /// mapping knows.
    @Test("ops the store records name entities the mapping recognises")
    func recordedOpsAreMappable() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let list = try store.createPlaylist(name: "Focus")
        try store.addTracks([TrackLink(jellyfinId: "t1", contentKey: "k1")], to: list.id)
        _ = try store.createFolder(name: "Mixes")
        try store.record(Like(jellyfinId: "t1", contentKey: "k1", liked: true, updatedAt: 1, originDevice: "phone"))
        try store.append(PlayEvent(jellyfinId: "t1", contentKey: "k1", startedAt: 1, originDevice: "phone"))
        try store.saveQueue(deviceName: "iPhone", trackIds: ["t1"], position: 0, elapsedMs: 0)

        let names = Set(try store.pendingOps(limit: 1_000).map(\.entity))
        #expect(names.count == 6)
        for name in names {
            #expect(SyncEntity(localTable: name) != nil, "unmapped entity '\(name)'")
        }
    }
}
