import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Playlist and folder editing")
struct PlaylistsTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func links(_ ids: [String]) -> [TrackLink] {
        ids.map { TrackLink(jellyfinId: $0, contentKey: "key-\($0)") }
    }

    /// Populates the local library mirror that `relinkItemsAgainstTrackCache` reads.
    private func cache(_ store: CurationStore, _ pairs: [(id: String, key: String)]) throws {
        try store.writeLocal { db in
            for pair in pairs {
                try TrackRef(
                    jellyfinId: pair.id,
                    contentKey: pair.key,
                    title: pair.id,
                    artist: "a",
                    album: "b",
                    lastSeenAt: 0
                ).insert(db)
            }
        }
    }

    // MARK: - The one that matters

    /// The whole reason positions are fractional. If a drag rewrites its neighbours
    /// too, two devices reordering at once produce conflicting updates and a
    /// last-writer-wins merge drops one of them.
    @Test("dragging a track rewrites exactly one row")
    func moveWritesOneRow() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Set", now: 1_000)
        let added = try store.addTracks(links(["a", "b", "c", "d", "e"]), to: list.id, now: 1_000)
        let opsBefore = try store.pendingOps().count

        let moved = try store.moveItem(added[4].id, in: list.id, to: 1, now: 2_000)

        let after = try store.items(in: list.id)
        #expect(after.map(\.jellyfinId) == ["a", "e", "b", "c", "d"])

        for row in after where row.id != moved.id {
            #expect(row.updatedAt == 1_000)
            #expect(row.position == added.first { $0.id == row.id }?.position)
        }

        let ops = try store.pendingOps()
        #expect(ops.count == opsBefore + 1)
        #expect(ops.last?.entityId == moved.id)
    }

    @Test("a drag that lands where it started writes nothing at all")
    func movingNowhereIsFree() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Still", now: 0)
        let added = try store.addTracks(links(["a", "b", "c"]), to: list.id, now: 0)
        let opsBefore = try store.pendingOps().count

        try store.moveItem(added[1].id, in: list.id, to: 1, now: 5_000)

        #expect(try store.pendingOps().count == opsBefore)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["a", "b", "c"])
        #expect(try store.items(in: list.id)[1].updatedAt == 0)
    }

    // MARK: - Ordering

    @Test("a track can be dragged to the front, the end and the middle")
    func moveToEdges() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Edges", now: 0)
        let added = try store.addTracks(links(["a", "b", "c", "d"]), to: list.id, now: 0)

        try store.moveItem(added[2].id, in: list.id, to: 0, now: 1)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["c", "a", "b", "d"])

        try store.moveItem(added[0].id, in: list.id, to: 3, now: 2)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["c", "b", "d", "a"])

        try store.moveItem(added[3].id, in: list.id, to: 1, now: 3)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["c", "d", "b", "a"])
    }

    /// Fractional keys lengthen as gaps are subdivided; the failure mode would be two
    /// rows converging on the same key and the order becoming arbitrary between them.
    @Test("order survives two hundred drags without keys colliding")
    func longSequenceOfDrags() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Churn", now: 0)
        var expected = (0..<12).map { "t\($0)" }
        try store.addTracks(links(expected), to: list.id, now: 0)

        var seed: UInt64 = 0x5EED
        func random(below bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }

        for step in 0..<200 {
            let current = try store.items(in: list.id)
            let from = random(below: current.count)
            let to = random(below: current.count)
            try store.moveItem(current[from].id, in: list.id, to: to, now: Millis(1_000 + step))

            expected.insert(expected.remove(at: from), at: to)
            #expect(try store.items(in: list.id).map(\.jellyfinId) == expected)
        }

        let final = try store.items(in: list.id)
        #expect(Set(final.map(\.position)).count == final.count)
    }

    @Test("tracks are appended in the order given, duplicates included")
    func appendOrderAndDuplicates() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Repeats", now: 0)
        try store.addTracks(links(["a", "b"]), to: list.id, now: 0)
        try store.addTracks(links(["a", "c"]), to: list.id, now: 1)

        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["a", "b", "a", "c"])
        #expect(try store.itemCount(in: list.id) == 4)
    }

    @Test("inserting a run puts it in order at the requested index")
    func insertRun() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Insert", now: 0)
        try store.addTracks(links(["a", "b", "c"]), to: list.id, now: 0)

        try store.insertTracks(links(["x", "y"]), into: list.id, at: 1, now: 1)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["a", "x", "y", "b", "c"])

        try store.insertTracks(links(["z"]), into: list.id, at: 0, now: 2)
        try store.insertTracks(links(["w"]), into: list.id, at: 99, now: 3)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["z", "a", "x", "y", "b", "c", "w"])
    }

    @Test("a removed track leaves the listing and the count but keeps its row")
    func removeItem() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Trim", now: 0)
        let added = try store.addTracks(links(["a", "b", "c"]), to: list.id, now: 0)

        try store.removeItem(added[1].id, now: 1)

        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["a", "c"])
        #expect(try store.itemCount(in: list.id) == 2)

        let rows = try store.read { try PlaylistItem.fetchAll($0) }
        #expect(rows.count == 3)
        #expect(rows.filter(\.deleted).count == 1)
    }

    @Test("removing twice does not emit a second delete op")
    func removeIsIdempotent() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Trim", now: 0)
        let added = try store.addTracks(links(["a"]), to: list.id, now: 0)

        try store.removeItem(added[0].id, now: 1)
        let ops = try store.pendingOps().count
        try store.removeItem(added[0].id, now: 2)
        #expect(try store.pendingOps().count == ops)
    }

    // MARK: - Playlists

    @Test("deleting a playlist takes its items out of every listing")
    func deleteCascadesToItems() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Gone", now: 0)
        let other = try store.createPlaylist(name: "Kept", now: 0)
        try store.addTracks(links(["a", "b", "c"]), to: list.id, now: 0)
        try store.addTracks(links(["d"]), to: other.id, now: 0)

        try store.deletePlaylist(list.id, now: 10)

        #expect(try store.playlists().map(\.id) == [other.id])
        #expect(try store.items(in: list.id).isEmpty)
        #expect(try store.itemCount(in: list.id) == 0)
        // The other playlist's items are untouched — the cascade is scoped.
        #expect(try store.items(in: other.id).count == 1)

        // Each removed item carries its own delete op; a bulk UPDATE would have
        // changed rows that never sync.
        let deletes = try store.pendingOps().filter { $0.entity == "playlistItem" && $0.operation == "delete" }
        #expect(deletes.count == 3)
    }

    /// Orphaned items would still match on content key, so the next relink pass would
    /// happily rewrite rows belonging to a playlist that no longer exists.
    @Test("no item of a deleted playlist survives a later relink")
    func deletedItemsAreNotRelinked() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Gone", now: 0)
        try store.addTracks(links(["old"]), to: list.id, now: 0)
        try store.deletePlaylist(list.id, now: 1)
        try cache(store, [(id: "new", key: "key-old")])

        let report = try store.relinkItemsAgainstTrackCache(now: 2)
        #expect(report.checked == 0)
        #expect(report.changed == 0)
    }

    @Test("deleting twice does not emit a second op")
    func deletePlaylistIsIdempotent() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Gone", now: 0)
        try store.deletePlaylist(list.id, now: 1)
        let ops = try store.pendingOps().count
        try store.deletePlaylist(list.id, now: 2)
        #expect(try store.pendingOps().count == ops)
    }

    @Test("renaming leaves the other fields alone")
    func renameKeepsFields() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Old", notes: "for driving", now: 0)
        let renamed = try store.rename(playlist: list.id, to: "New", now: 5)

        #expect(renamed.name == "New")
        #expect(renamed.notes == "for driving")
        #expect(renamed.sortIndex == list.sortIndex)
        #expect(renamed.updatedAt == 5)

        let cleared = try store.setNotes(nil, on: list.id, now: 6)
        #expect(cleared.name == "New")
        #expect(cleared.notes == nil)
    }

    @Test("playlists list in sort order and filter by folder")
    func listingAndFiling() throws {
        let store = try store()
        let folder = try store.createFolder(name: "Moods", now: 0)
        let first = try store.createPlaylist(name: "One", now: 0)
        let second = try store.createPlaylist(name: "Two", folderId: folder.id, now: 0)
        let third = try store.createPlaylist(name: "Three", now: 0)

        #expect(try store.playlists().map(\.name) == ["One", "Two", "Three"])
        #expect(try store.playlists(inFolder: folder.id).map(\.id) == [second.id])
        #expect(try store.playlists(inFolder: nil).map(\.id) == [first.id, third.id])

        // Moving into a folder appends there, so the flat listing follows.
        try store.move(playlist: first.id, toFolder: folder.id, now: 1)
        #expect(try store.playlists(inFolder: folder.id).map(\.name) == ["Two", "One"])
        #expect(try store.playlists(inFolder: nil).map(\.id) == [third.id])
    }

    @Test("a playlist can be reordered to the top and back down")
    func reorderPlaylists() throws {
        let store = try store()
        let a = try store.createPlaylist(name: "A", now: 0)
        let b = try store.createPlaylist(name: "B", now: 0)
        let c = try store.createPlaylist(name: "C", now: 0)

        try store.reorderPlaylist(c.id, before: a.id, now: 1)
        #expect(try store.playlists().map(\.name) == ["C", "A", "B"])

        try store.reorderPlaylist(c.id, after: a.id, before: b.id, now: 2)
        #expect(try store.playlists().map(\.name) == ["A", "C", "B"])

        try store.reorderPlaylist(a.id, after: b.id, now: 3)
        #expect(try store.playlists().map(\.name) == ["C", "B", "A"])
    }

    /// FractionalIndex only asserts on this, and assertions are gone in release — so
    /// the check has to be a real one or the order corrupts silently in the shipped
    /// build.
    @Test("neighbours the wrong way round are refused, not bisected")
    func reversedNeighboursThrow() throws {
        let store = try store()
        let a = try store.createPlaylist(name: "A", now: 0)
        let b = try store.createPlaylist(name: "B", now: 0)
        let c = try store.createPlaylist(name: "C", now: 0)

        #expect(throws: PlaylistError.badNeighbours) {
            try store.reorderPlaylist(c.id, after: b.id, before: a.id, now: 1)
        }
        // A row cannot be its own neighbour either; a UI that computed neighbours
        // from the unfiltered list would hand one over.
        #expect(throws: PlaylistError.badNeighbours) {
            try store.reorderPlaylist(b.id, after: b.id, now: 1)
        }
        #expect(try store.playlists().map(\.name) == ["A", "B", "C"])
    }

    @Test("editing something that was deleted is refused")
    func editingDeletedIsRefused() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Gone", now: 0)
        try store.deletePlaylist(list.id, now: 1)

        #expect(throws: PlaylistError.self) { try store.rename(playlist: list.id, to: "Back", now: 2) }
        #expect(throws: PlaylistError.self) { try store.addTracks(self.links(["a"]), to: list.id, now: 2) }
        #expect(try store.playlist(list.id) == nil)
    }

    // MARK: - Folders

    /// A folder that is its own ancestor is not merely wrong data: every tree walk
    /// over it runs forever.
    @Test("a folder cannot be moved under itself or its own descendant")
    func folderCycles() throws {
        let store = try store()
        let root = try store.createFolder(name: "Root", now: 0)
        let child = try store.createFolder(name: "Child", parentId: root.id, now: 0)
        let grandchild = try store.createFolder(name: "Grandchild", parentId: child.id, now: 0)

        #expect(throws: PlaylistError.self) { try store.move(folder: root.id, toParent: root.id, now: 1) }
        #expect(throws: PlaylistError.self) { try store.move(folder: root.id, toParent: child.id, now: 1) }
        #expect(throws: PlaylistError.self) { try store.move(folder: root.id, toParent: grandchild.id, now: 1) }

        #expect(try store.folder(root.id)?.parentId == nil)

        // Downward moves are still fine.
        let sibling = try store.createFolder(name: "Sibling", now: 0)
        try store.move(folder: sibling.id, toParent: grandchild.id, now: 2)
        #expect(try store.folder(sibling.id)?.parentId == grandchild.id)
    }

    /// Per-field last-writer-wins can merge two individually legal moves into a
    /// cycle, so the ancestry walk has to survive a graph it did not build.
    @Test("the ancestry walk terminates on a cycle that arrived from sync")
    func ancestryWalkTerminatesOnSyncedCycle() throws {
        let store = try store()
        let a = try store.createFolder(name: "A", now: 0)
        let b = try store.createFolder(name: "B", parentId: a.id, now: 0)

        // What a merge of two concurrent moves leaves behind.
        try store.writeLocal { db in
            try db.execute(sql: "UPDATE folder SET parentId = ? WHERE id = ?", arguments: [b.id, a.id])
        }

        let c = try store.createFolder(name: "C", now: 1)
        #expect(throws: PlaylistError.self) { try store.move(folder: c.id, toParent: b.id, now: 2) }
    }

    /// Cascading would destroy playlists on a gesture that reads as "stop organising
    /// this way", and leaving folderId dangling would hide them from every listing —
    /// a delete with extra steps.
    @Test("deleting a folder promotes its contents one level rather than losing them")
    func deleteFolderPromotes() throws {
        let store = try store()
        let outer = try store.createFolder(name: "Outer", now: 0)
        let inner = try store.createFolder(name: "Inner", parentId: outer.id, now: 0)
        let list = try store.createPlaylist(name: "Kept", folderId: inner.id, now: 0)
        try store.addTracks(links(["a"]), to: list.id, now: 0)

        try store.deleteFolder(inner.id, now: 10)

        #expect(try store.folder(inner.id) == nil)
        #expect(try store.playlist(list.id)?.folderId == outer.id)
        #expect(try store.playlists(inFolder: outer.id).map(\.id) == [list.id])
        #expect(try store.items(in: list.id).count == 1)

        // And one level up again, to the root.
        try store.deleteFolder(outer.id, now: 11)
        #expect(try store.playlist(list.id)?.folderId == nil)
        #expect(try store.playlists(inFolder: nil).map(\.id) == [list.id])
        #expect(try store.folders().isEmpty)
    }

    @Test("folders list, rename and reorder")
    func folderBasics() throws {
        let store = try store()
        let a = try store.createFolder(name: "A", now: 0)
        let b = try store.createFolder(name: "B", now: 0)
        let nested = try store.createFolder(name: "Nested", parentId: a.id, now: 0)

        #expect(try store.folders().map(\.name) == ["A", "B", "Nested"])
        #expect(try store.folders(inParent: nil).map(\.name) == ["A", "B"])
        #expect(try store.folders(inParent: a.id).map(\.id) == [nested.id])

        try store.rename(folder: b.id, to: "Renamed", now: 1)
        #expect(try store.folder(b.id)?.name == "Renamed")

        try store.reorderFolder(b.id, before: a.id, now: 2)
        #expect(try store.folders(inParent: nil).map(\.name) == ["Renamed", "A"])
    }

    @Test("creating inside a folder that does not exist is refused")
    func unknownFolderRefused() throws {
        let store = try store()
        #expect(throws: PlaylistError.self) { try store.createPlaylist(name: "Orphan", folderId: "nope", now: 0) }
        #expect(throws: PlaylistError.self) { try store.createFolder(name: "Orphan", parentId: "nope", now: 0) }
    }

    // MARK: - Relinking

    @Test("a rescan that mints new ids is repaired by content key")
    func relinkByContentKey() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        try store.addTracks(
            [TrackLink(jellyfinId: "old-1", contentKey: "k1"), TrackLink(jellyfinId: "old-2", contentKey: "k2")],
            to: list.id,
            now: 0
        )
        try cache(store, [(id: "new-1", key: "k1"), (id: "new-2", key: "k2")])

        let report = try store.relinkItemsAgainstTrackCache(now: 10)

        #expect(report == RelinkReport(checked: 2, relinked: 2, recovered: 0, unresolved: 0))
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["new-1", "new-2"])
        #expect(try store.items(in: list.id).allSatisfy { !$0.isUnresolved })
    }

    /// The drive may simply be unmounted. Deleting the entry for that is
    /// unrecoverable; marking it is not.
    @Test("a track that matches nothing is marked, never deleted")
    func unmatchedIsMarked() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        try store.addTracks(
            [TrackLink(jellyfinId: "old-1", contentKey: "k1"), TrackLink(jellyfinId: "old-2", contentKey: "k2")],
            to: list.id,
            now: 0
        )
        try cache(store, [(id: "new-1", key: "k1")])

        let report = try store.relinkItemsAgainstTrackCache(now: 10)
        #expect(report == RelinkReport(checked: 2, relinked: 1, recovered: 0, unresolved: 1))

        let items = try store.items(in: list.id)
        #expect(items.count == 2)
        let missing = try #require(items.first { $0.isUnresolved })
        #expect(missing.linkedJellyfinId == "old-2")
        #expect(missing.contentKey == "k2")

        // A second pass has nothing new to say, and must not write an op saying it.
        let ops = try store.pendingOps().count
        let again = try store.relinkItemsAgainstTrackCache(now: 11)
        #expect(again.changed == 0)
        #expect(try store.pendingOps().count == ops)
    }

    @Test("a marked track is unmarked when the drive comes back")
    func markedTrackRecovers() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        try store.addTracks([TrackLink(jellyfinId: "old-1", contentKey: "k1")], to: list.id, now: 0)
        try cache(store, [(id: "unrelated", key: "other")])

        #expect(try store.relinkItemsAgainstTrackCache(now: 1).unresolved == 1)
        try cache(store, [(id: "old-1", key: "k1")])

        let report = try store.relinkItemsAgainstTrackCache(now: 2)
        #expect(report == RelinkReport(checked: 1, relinked: 0, recovered: 1, unresolved: 0))

        let item = try #require(try store.items(in: list.id).first)
        #expect(!item.isUnresolved)
        #expect(item.jellyfinId == "old-1")
    }

    /// The first launch after an install has an empty cache and a full library. The
    /// two are indistinguishable to a naive relink, which would mark everything.
    @Test("an unscanned library does not mark the whole collection missing")
    func emptyCacheIsNotAnEmptyLibrary() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        try store.addTracks(links(["a", "b"]), to: list.id, now: 0)
        let ops = try store.pendingOps().count

        let report = try store.relinkItemsAgainstTrackCache(now: 10)

        #expect(report == RelinkReport())
        #expect(try store.pendingOps().count == ops)
        #expect(try store.items(in: list.id).allSatisfy { !$0.isUnresolved })
    }

    @Test("relinking rewrites the row and its op, so the repair syncs")
    func relinkRecordsOps() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        let added = try store.addTracks([TrackLink(jellyfinId: "old-1", contentKey: "k1")], to: list.id, now: 0)
        try cache(store, [(id: "new-1", key: "k1")])

        try store.relinkItemsAgainstTrackCache(now: 10)

        let op = try #require(try store.pendingOps().last)
        #expect(op.entity == "playlistItem")
        #expect(op.entityId == added[0].id)
        #expect(op.operation == "upsert")
        #expect(op.payload.contains("new-1"))
        // Position untouched: a relink changes identity, never order.
        #expect(try store.items(in: list.id)[0].position == added[0].position)
    }

    @Test("relinking leaves an id that still resolves completely alone")
    func liveTracksAreUntouched() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)
        try store.addTracks([TrackLink(jellyfinId: "live", contentKey: "k1")], to: list.id, now: 0)
        try cache(store, [(id: "live", key: "k1"), (id: "duplicate", key: "k1")])

        let report = try store.relinkItemsAgainstTrackCache(now: 10)
        #expect(report.changed == 0)
        #expect(try store.items(in: list.id)[0].updatedAt == 0)
    }
}
