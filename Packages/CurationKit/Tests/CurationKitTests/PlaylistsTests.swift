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

/// A copy, not a link. Jellyfin cannot tell us when it changed, so a local playlist
/// that silently drifted from the server one it claims to mirror would be worse than
/// an honest snapshot.
@Suite("Importing from Jellyfin")
struct PlaylistImportTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func links(_ ids: [String]) -> [TrackLink] {
        ids.map { TrackLink(jellyfinId: $0, contentKey: "key-\($0)") }
    }

    @Test("importing copies the server's songs in order")
    func imports() throws {
        let store = try store()
        let list = try store.importPlaylist(named: "Road Trip", from: "srv-1", tracks: links(["a", "b", "c"]))

        #expect(list.name == "Road Trip")
        #expect(list.sourceJellyfinId == "srv-1")
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["a", "b", "c"])
    }

    /// The obvious mistake: tapping import twice must not leave two playlists.
    @Test("importing the same playlist twice refreshes one copy rather than making two")
    func refreshesRatherThanDuplicating() throws {
        let store = try store()
        let first = try store.importPlaylist(named: "Road Trip", from: "srv-1", tracks: links(["a", "b"]))
        let second = try store.importPlaylist(named: "Road Trip", from: "srv-1", tracks: links(["a", "b", "c"]))

        #expect(first.id == second.id)
        #expect(try store.playlists().count == 1)
        #expect(try store.items(in: second.id).map(\.jellyfinId) == ["a", "b", "c"])
    }

    /// The server's contents are the answer, so a song removed there is removed here.
    @Test("a refresh drops songs the server no longer has")
    func refreshRemoves() throws {
        let store = try store()
        let list = try store.importPlaylist(named: "Trimmed", from: "srv-2", tracks: links(["a", "b", "c"]))
        try store.importPlaylist(named: "Trimmed", from: "srv-2", tracks: links(["b"]))

        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["b"])
    }

    /// Removals have to travel: a device that only truncated locally would leave every
    /// other device holding the old contents forever.
    @Test("a refresh emits a delete op for every song it drops")
    func refreshEmitsOps() throws {
        let store = try store()
        try store.importPlaylist(named: "Trimmed", from: "srv-3", tracks: links(["a", "b"]))
        let before = try store.pendingOps().filter { $0.operation == "delete" }.count

        try store.importPlaylist(named: "Trimmed", from: "srv-3", tracks: links(["a"]))

        let after = try store.pendingOps().filter { $0.operation == "delete" }.count
        #expect(after == before + 2, "both old rows have to be told to the other devices")
    }

    @Test("playlists made by hand are untouched by an import of the same name")
    func handMadeIsSeparate() throws {
        let store = try store()
        let mine = try store.createPlaylist(name: "Road Trip")
        try store.addTracks(links(["x"]), to: mine.id)

        try store.importPlaylist(named: "Road Trip", from: "srv-1", tracks: links(["a"]))

        #expect(try store.playlists().count == 2)
        #expect(try store.items(in: mine.id).map(\.jellyfinId) == ["x"])
    }

    @Test("the imported set names exactly the server playlists that have a copy")
    func importedIds() throws {
        let store = try store()
        try store.importPlaylist(named: "One", from: "srv-1", tracks: links(["a"]))
        _ = try store.createPlaylist(name: "By Hand")

        #expect(try store.importedSourceIds() == ["srv-1"])

        // A deleted copy stops counting, so the server row offers to copy again.
        let copy = try #require(try store.importedPlaylist(from: "srv-1"))
        try store.deletePlaylist(copy.id)
        #expect(try store.importedSourceIds().isEmpty)
    }
}

/// Covers are ids, never image bytes. The op log replays in full onto every new
/// device and payloads are capped at 256 KB, so a cover held as data would be the
/// largest thing in the system and would be copied forever.
@Suite("Playlist covers")
struct PlaylistCoverTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func cache(_ store: CurationStore, track: String, album: String) throws {
        try store.cacheTracks([TrackRef(
            jellyfinId: track,
            contentKey: "key-\(track)",
            title: track,
            artist: "Artist",
            album: album,
            albumId: album,
            lastSeenAt: 1
        )])
    }

    @Test("choosing a cover syncs as an id and nothing else")
    func coverIsAnId() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Covered")

        let saved = try #require(try store.setArtwork("album-7", on: list.id))
        #expect(saved.artworkItemId == "album-7")

        let op = try #require(try store.pendingOps().last { $0.entityId == list.id })
        #expect(op.payload.contains("album-7"))
        // The whole row, cover included, stays small enough that it could never
        // approach the payload ceiling.
        #expect(op.payload.count < 2_000)
    }

    @Test("clearing a cover goes back to the mosaic")
    func clearing() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Covered")
        try store.setArtwork("album-7", on: list.id)

        let cleared = try #require(try store.setArtwork(nil, on: list.id))
        #expect(cleared.artworkItemId == nil)
    }

    /// Distinct albums, not distinct tracks: a playlist of one album would otherwise
    /// tile the same square four times, which reads as a rendering bug.
    @Test("the mosaic draws from distinct albums in playing order")
    func mosaicAlbums() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Mixed")
        for (track, album) in [("t1", "a1"), ("t2", "a1"), ("t3", "a2"), ("t4", "a3")] {
            try cache(store, track: track, album: album)
        }
        try store.addTracks(
            [("t1", "a1"), ("t2", "a1"), ("t3", "a2"), ("t4", "a3")]
                .map { TrackLink(jellyfinId: $0.0, contentKey: "key-\($0.0)") },
            to: list.id
        )

        let covers = try store.coverAlbums(for: [list.id])
        #expect(covers[list.id] == ["a1", "a2", "a3"])
    }

    @Test("a removed song stops contributing its album")
    func removedSongsDropOut() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Trimmed")
        for (track, album) in [("t1", "a1"), ("t2", "a2")] {
            try cache(store, track: track, album: album)
        }
        let items = try store.addTracks(
            [TrackLink(jellyfinId: "t1", contentKey: "key-t1"),
             TrackLink(jellyfinId: "t2", contentKey: "key-t2")],
            to: list.id
        )
        try store.removeItem(try #require(items.first).id)

        #expect(try store.coverAlbums(for: [list.id])[list.id] == ["a2"])
    }

    /// One query answers a whole screen. Per playlist it would be one query per row.
    @Test("covers for many playlists come back in one call")
    func batched() throws {
        let store = try store()
        try cache(store, track: "t1", album: "a1")
        var ids: [String] = []
        for index in 0..<3 {
            let list = try store.createPlaylist(name: "List \(index)")
            try store.addTracks([TrackLink(jellyfinId: "t1", contentKey: "key-t1")], to: list.id)
            ids.append(list.id)
        }
        let covers = try store.coverAlbums(for: ids)
        #expect(covers.count == 3)
        #expect(covers.values.allSatisfy { $0 == ["a1"] })
    }
}

/// Cover bytes travel outside the op log, and the one rule that makes that safe is
/// ordering: the blob must reach the server before any op that names it.
@Suite("Cover blobs")
struct ImageBlobTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private let bytes = Data("not really a jpeg, but bytes are bytes".utf8)

    @Test("the hash is the lower-case hex the server addresses by")
    func hashing() {
        let hash = CurationStore.imageHash(of: bytes)
        #expect(hash.count == 64)
        #expect(hash == hash.lowercased())
        #expect(CurationStore.imageHash(of: bytes) == hash, "same bytes, same name")
    }

    /// The whole ordering rule, made answerable. An op naming a hash the server does
    /// not hold leaves every other device with a cover it can never fetch.
    @Test("an op naming an unuploaded cover holds that cover back for upload")
    func pendingUploads() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count)

        let list = try store.createPlaylist(name: "Photographed")
        var row = try #require(try store.playlist(list.id))
        row.imageHash = hash
        try store.record(row)

        #expect(try store.imagesNeededBeforePush().map(\.hash) == [hash])

        try store.markImageUploaded(hash)
        #expect(try store.imagesNeededBeforePush().isEmpty)
    }

    @Test("a cover nothing references is not queued for upload")
    func unreferencedIsNotUploaded() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count)
        _ = try store.createPlaylist(name: "No Photo")

        #expect(try store.imagesNeededBeforePush().isEmpty)
    }

    /// Re-registering must not un-mark an upload, or every sync would send the same
    /// bytes again forever.
    @Test("registering the same bytes twice keeps the upload mark")
    func registerIsIdempotent() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count)
        try store.markImageUploaded(hash, at: 500)

        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count)
        #expect(try store.image(hash)?.uploadedAt == 500)
    }

    /// A cover dropped here may still be named by a playlist another device has not
    /// synced yet, and content addressing makes re-adding it free — so this reports
    /// rather than reclaims.
    @Test("a cover no playlist names is reported as orphaned, not deleted")
    func orphans() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count, at: 100)

        let wellPast = Millis(100) + Millis(31) * 24 * 60 * 60 * 1000
        #expect(try store.orphanedImages(now: wellPast).map(\.hash) == [hash])

        let list = try store.createPlaylist(name: "Uses It")
        var row = try #require(try store.playlist(list.id))
        row.imageHash = hash
        try store.record(row)

        #expect(try store.orphanedImages(now: wellPast).isEmpty)
        #expect(try store.image(hash) != nil, "reported, never reclaimed")
    }

    /// "Nothing references this" is only ever true *here*. A device out of contact
    /// for a fortnight is a phone in a drawer, not a device that has been replaced.
    @Test("a freshly orphaned cover is left alone until the grace period is up")
    func gracePeriodIsRespected() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count, at: 0)

        let day: Millis = 24 * 60 * 60 * 1000
        #expect(try store.orphanedImages(now: 29 * day).isEmpty)
        #expect(try store.orphanedImages(now: 31 * day).count == 1)
    }

    /// Asking to sweep sooner is asking to defeat the reason the period exists, and
    /// the code that deletes data is the wrong place to take that instruction.
    @Test("a shorter grace than the configured one is raised, not honoured")
    func shortGraceIsRaised() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count, at: 0)

        let day: Millis = 24 * 60 * 60 * 1000
        #expect(try store.orphanedImages(olderThanDays: 1, now: 5 * day).isEmpty)
        #expect(try store.orphanedImages(olderThanDays: 0, now: 5 * day).isEmpty)
        // A longer one is taken at its word — that direction is only more cautious.
        #expect(try store.orphanedImages(olderThanDays: 90, now: 31 * day).isEmpty)
    }

    /// Content addressing makes sharing normal, and a sweep that reasoned one
    /// playlist at a time would delete a cover the other one is still using.
    @Test("a cover shared by two playlists survives losing one of them")
    func sharedCoversSurvive() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count, at: 0)

        var ids: [String] = []
        for name in ["First", "Second"] {
            let list = try store.createPlaylist(name: name)
            var row = try #require(try store.playlist(list.id))
            row.imageHash = hash
            try store.record(row)
            ids.append(list.id)
        }

        let day: Millis = 24 * 60 * 60 * 1000
        try store.deletePlaylist(ids[0])
        #expect(try store.orphanedImages(now: 31 * day).isEmpty, "the other playlist still uses it")

        try store.deletePlaylist(ids[1])
        #expect(try store.orphanedImages(now: 31 * day).map(\.hash) == [hash])
    }

    @Test("forgetting a blob is a separate, explicit step")
    func forgettingIsSeparate() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count, at: 0)

        let day: Millis = 24 * 60 * 60 * 1000
        let orphans = try store.orphanedImages(now: 31 * day)
        #expect(try store.image(hash) != nil, "reporting removes nothing")

        #expect(try store.forgetImages(orphans.map(\.hash)) == 1)
        #expect(try store.image(hash) == nil)
    }

    /// The row carries a name, not a picture — the property the whole sync design
    /// rests on.
    @Test("a cover adds only a hash to the op, never bytes")
    func opsStaySmall() throws {
        let store = try store()
        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: 250_000)

        let list = try store.createPlaylist(name: "Photographed")
        var row = try #require(try store.playlist(list.id))
        row.imageHash = hash
        row.imageMime = "image/jpeg"
        try store.record(row)

        let op = try #require(try store.pendingOps().last { $0.entityId == list.id })
        #expect(op.payload.contains(hash))
        #expect(op.payload.count < 2_000, "a quarter-megabyte cover must not be in here")
    }
}

/// Export adoption on the sidecar matches an Aoide playlist to a Jellyfin one by
/// name, so what import does to names decides whether adoption finds them.
@Suite("Import for export adoption")
struct ImportForAdoptionTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func links(_ ids: [String]) -> [TrackLink] {
        ids.map { TrackLink(jellyfinId: $0, contentKey: "key-\($0)") }
    }

    /// The name is the join. A copy that renamed, trimmed or decorated it would make
    /// adoption miss and the exporter create a duplicate alongside the original.
    @Test("a copy keeps the server playlist's name exactly")
    func nameIsPreservedExactly() throws {
        let store = try store()
        for name in ["Road Trip", "  Padded  ", "Café — 90s", "Copy"] {
            let list = try store.importPlaylist(named: name, from: "srv-\(name)", tracks: links(["a"]))
            #expect(list.name == name)
        }
    }

    /// Adoption needs exactly one same-named candidate, so two server playlists
    /// sharing a name are ambiguous and the sidecar will create a new one rather than
    /// guess. Import must at least not *add* to the ambiguity by inventing collisions.
    @Test("two server playlists sharing a name stay two distinct copies")
    func duplicateNamesStayDistinct() throws {
        let store = try store()
        let first = try store.importPlaylist(named: "Favourites", from: "srv-1", tracks: links(["a"]))
        let second = try store.importPlaylist(named: "Favourites", from: "srv-2", tracks: links(["b"]))

        #expect(first.id != second.id)
        #expect(try store.playlists().count == 2)
        #expect(first.sourceJellyfinId == "srv-1")
        #expect(second.sourceJellyfinId == "srv-2")
    }

    /// `sourceJellyfinId` is an exact mapping the client already has, and it travels
    /// in the payload — so the sidecar can match on it instead of guessing by name
    /// for every playlist that came from an import.
    @Test("a copy records exactly which server playlist it came from")
    func sourceIsRecorded() throws {
        let store = try store()
        let list = try store.importPlaylist(named: "Road Trip", from: "srv-42", tracks: links(["a"]))

        let op = try #require(try store.pendingOps().last { $0.entityId == list.id })
        #expect(op.payload.contains("srv-42"), "the mapping has to reach the server to be usable there")
    }
}

/// The exporter that puts art on a Jellyfin playlist has a hash and nothing else, so
/// a cover that never becomes bytes is a cover that exists in Aoide alone.
@Suite("Covers that reach the server")
struct CoverPublishingTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }
    private let bytes = Data("cover bytes".utf8)

    @Test("a cover chosen as an album carries no hash until it is published")
    func referenceAloneIsNotEnough() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Chosen")
        try store.setArtwork("album-1", on: list.id)

        let row = try #require(try store.playlist(list.id))
        #expect(row.artworkItemId == "album-1")
        // Nothing to export yet: the reference is an instruction only this app can
        // carry out.
        #expect(row.imageHash == nil)
        #expect(try store.imagesNeededBeforePush().isEmpty)
    }

    @Test("publishing gives it bytes, a hash, and a place in the upload queue")
    func publishingMakesItExportable() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Chosen")
        try store.setArtwork("album-1", on: list.id)

        let hash = CurationStore.imageHash(of: bytes)
        try store.registerImage(hash: hash, mime: "image/jpeg", bytes: bytes.count)
        var row = try #require(try store.playlist(list.id))
        row.imageHash = hash
        row.imageMime = "image/jpeg"
        try store.record(row)

        #expect(try store.imagesNeededBeforePush().map(\.hash) == [hash])
        // The reference is kept: it still says what the cover is, and is what a
        // republish would work from if the blob were ever lost.
        #expect(try store.playlist(list.id)?.artworkItemId == "album-1")
    }

    /// A cover that stopped being true is worse than no cover: Jellyfin builds its own
    /// collage for a playlist with no artwork, which is the same picture kept honest.
    @Test("a playlist with only a mosaic has nothing to publish")
    func mosaicsAreNotPublished() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Derived")

        let row = try #require(try store.playlist(list.id))
        #expect(row.artworkItemId == nil)
        #expect(row.imageHash == nil)
    }
}
