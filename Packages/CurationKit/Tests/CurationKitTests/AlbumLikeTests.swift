import Foundation
import GRDB
import Testing
@testable import CurationKit

/// Album likes: pulled and merged as a track's like is, in a table of their own.
@Suite("Album likes")
struct AlbumLikeTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func albumLike(_ id: String, album: String = "1", at updatedAt: Millis, by device: String) -> AlbumLike {
        AlbumLike(id: id, albumId: album, contentKey: "bjork|post", liked: true, updatedAt: updatedAt, originDevice: device)
    }

    @Test("the entity is named as the server names it, and never held back")
    func names() {
        #expect(SyncEntity.albumLike.wireName == "album_likes")
        #expect(SyncEntity.albumLike.localTable == AlbumLike.databaseTableName)
        // Never written here, so a server without album likes holds nothing back.
        #expect(!SyncEntity.albumLike.needsServerSupport)
    }

    @Test("a pulled album like is kept and likes no track")
    func pulled() throws {
        let store = try store()
        let row = albumLike("A", at: 2_000, by: "web")
        let report = try store.applyOne(try Wire.pulled(.albumLike, row, entityId: "A"))
        #expect(report.applied == 1)
        #expect(report.quarantinedInbound == 0)
        #expect(try store.read { try AlbumLike.fetchAll($0) } == [row])
        #expect(try store.read { try Like.fetchCount($0) } == 0)
    }

    /// As with a track, two devices liking one album offline mint two rows.
    @Test("two likes of one album collapse to the later")
    func duplicates() throws {
        let store = try store()
        _ = try store.applyOne(try Wire.pulled(.albumLike, albumLike("A", at: 1_000, by: "phone"), entityId: "A"))
        let later = albumLike("B", at: 3_000, by: "web")
        let report = try store.applyOne(try Wire.pulled(.albumLike, later, entityId: "B", seq: 2))
        #expect(report.supersededLikes == 1)
        #expect(try store.read { try AlbumLike.fetchAll($0) } == [later])
    }

    @Test("a withdrawn album like is a tombstone")
    func withdrawn() throws {
        let store = try store()
        _ = try store.applyOne(try Wire.pulled(.albumLike, albumLike("A", at: 1_000, by: "web"), entityId: "A"))
        var gone = albumLike("A", at: 2_000, by: "web")
        gone.deleted = true
        let report = try store.applyOne(try Wire.pulled(.albumLike, gone, entityId: "A", operation: .delete, seq: 2))
        #expect(report.applied == 1)
        #expect(try store.read { try AlbumLike.fetchOne($0, key: "A") }?.deleted == true)
    }

    /// A row without `albumId` (a track's like sent under the wrong entity) can't be read.
    @Test("a track's row under the album entity is set aside")
    func trackRow() throws {
        let store = try store()
        let row = Like(id: "T", jellyfinId: "7", contentKey: "k", liked: true, updatedAt: 1, originDevice: "web")
        let report = try store.applyOne(try Wire.pulled(.albumLike, row, entityId: "T"))
        #expect(report.quarantinedInbound == 1)
        #expect(try store.read { try AlbumLike.fetchCount($0) } == 0)
    }
}
