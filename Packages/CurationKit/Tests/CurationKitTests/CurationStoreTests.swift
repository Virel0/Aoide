import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Curation store")
struct CurationStoreTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func playlist(_ name: String) -> Playlist {
        Playlist(name: name, sortIndex: FractionalIndex.initial, updatedAt: 0, originDevice: "")
    }

    /// The invariant the whole sync design rests on. A row saved without its op is a
    /// change that silently never leaves the device, and nothing afterwards can
    /// detect that it happened.
    @Test("saving a row writes its op in the same breath")
    func rowAndOpTogether() throws {
        let store = try store()
        let saved = try store.record(playlist("Late Night"))

        let ops = try store.pendingOps()
        #expect(ops.count == 1)
        #expect(ops[0].entity == "playlist")
        #expect(ops[0].entityId == saved.id)
        #expect(ops[0].operation == "upsert")
    }

    @Test("every write is stamped with this device and the time")
    func stamping() throws {
        let store = try store()
        let saved = try store.record(playlist("Focus"), at: 1_700_000_000_000)
        #expect(saved.originDevice == "phone")
        #expect(saved.updatedAt == 1_700_000_000_000)
    }

    /// A hard delete cannot be transmitted: the absence of a row is indistinguishable
    /// from never having seen it, so it would resurrect from any device still holding
    /// a copy.
    @Test("deleting soft-deletes and emits a delete op")
    func softDelete() throws {
        let store = try store()
        let saved = try store.record(playlist("Temporary"))
        try store.record(saved, deleted: true)

        let rows = try store.read { try Playlist.fetchAll($0) }
        #expect(rows.count == 1)
        #expect(rows[0].deleted)

        let ops = try store.pendingOps()
        #expect(ops.map(\.operation) == ["upsert", "delete"])
    }

    @Test("acknowledged ops stop being pending, and the rest remain")
    func markSynced() throws {
        let store = try store()
        let first = try store.record(playlist("One"))
        _ = try store.record(playlist("Two"))

        let ops = try store.pendingOps()
        let firstOp = try #require(ops.first { $0.entityId == first.id })
        try store.markSynced([firstOp.opId])

        let remaining = try store.pendingOps()
        #expect(remaining.count == 1)
        #expect(remaining[0].entityId != first.id)
    }

    @Test("pending ops come back oldest first, so they replay in order")
    func opsAreOrdered() throws {
        let store = try store()
        for (index, name) in ["A", "B", "C"].enumerated() {
            _ = try store.record(playlist(name), at: Millis(1000 + index))
        }
        let ops = try store.pendingOps()
        #expect(ops.map(\.createdAt) == [1000, 1001, 1002])
    }

    @Test("history is appended with its op and never edited")
    func playEvents() throws {
        let store = try store()
        let event = PlayEvent(
            jellyfinId: "track1",
            contentKey: "k",
            startedAt: 5_000,
            endedAt: 8_000,
            msPlayed: 3_000,
            skipped: true,
            source: .playlist,
            originDevice: "phone"
        )
        try store.append(event)

        let stored = try store.read { try PlayEvent.fetchAll($0) }
        #expect(stored.count == 1)
        #expect(stored[0].skipped)
        #expect(stored[0].source == "playlist")
        #expect(try store.pendingOps().count == 1)
    }

    @Test("the sync cursor round-trips and overwrites rather than accumulating")
    func cursor() throws {
        let store = try store()
        #expect(try store.syncCursor() == nil)
        try store.setSyncCursor("100")
        try store.setSyncCursor("250")
        #expect(try store.syncCursor() == "250")
    }

    @Test("playlist items order by their fractional position")
    func itemOrdering() throws {
        let store = try store()
        let list = try store.record(playlist("Ordered"))

        var previous: String?
        for index in 0..<5 {
            let position = FractionalIndex.between(previous, nil)
            previous = position
            _ = try store.record(PlaylistItem(
                playlistId: list.id,
                jellyfinId: "track\(index)",
                contentKey: "k\(index)",
                position: position,
                updatedAt: 0,
                originDevice: ""
            ))
        }

        // Insert between the first two, exactly as a drag would.
        let items = try store.read {
            try PlaylistItem.order(Column("position")).fetchAll($0)
        }
        _ = try store.record(PlaylistItem(
            playlistId: list.id,
            jellyfinId: "inserted",
            contentKey: "ki",
            position: FractionalIndex.between(items[0].position, items[1].position),
            updatedAt: 0,
            originDevice: ""
        ))

        let final = try store.read {
            try PlaylistItem.order(Column("position")).fetchAll($0)
        }
        #expect(final.map(\.jellyfinId) == ["track0", "inserted", "track1", "track2", "track3", "track4"])
    }

    /// Rounded to the second and normalised, because it exists to match the same
    /// recording after a rescan changed its id — not to be a checksum.
    @Test("the content key survives the differences a rescan introduces")
    func contentKey() {
        let a = ContentKey.make(artist: "Björk", album: "Post", title: "Army of Me", durationMs: 234_100)
        let b = ContentKey.make(artist: "  bjork ", album: "post", title: "ARMY OF ME", durationMs: 234_400)
        #expect(a == b)

        let different = ContentKey.make(artist: "Björk", album: "Post", title: "Hyperballad", durationMs: 234_100)
        #expect(a != different)
    }
}
