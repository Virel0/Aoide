import Foundation
import GRDB

// MARK: - References

/// The pair a playlist entry stores for every track: the id Jellyfin answers to
/// today, and the fingerprint that outlives it.
///
/// Both halves are kept because Jellyfin item ids are derived per-file — moving
/// files or re-adding a library mints new ones on the next scan. An entry holding
/// only an id would dangle with nothing left to search by; `relinkItems` is what
/// the second half is for.
public struct TrackLink: Hashable, Sendable {
    public var jellyfinId: String
    public var contentKey: String

    public init(jellyfinId: String, contentKey: String) {
        self.jellyfinId = jellyfinId
        self.contentKey = contentKey
    }

    /// From a cached library row, which already carries both halves.
    public init(_ track: TrackRef) {
        self.init(jellyfinId: track.jellyfinId, contentKey: track.contentKey)
    }
}

public enum PlaylistError: Error, Equatable, Sendable {
    case noSuchPlaylist(String)
    case noSuchFolder(String)
    case noSuchItem(String)
    case itemNotInPlaylist(item: String, playlist: String)
    /// A folder was asked to become its own ancestor.
    case folderCycle(folder: String, under: String)
    /// The neighbours handed to a reorder bracket no gap: either they are the wrong
    /// way round, or one of them is the row being moved.
    case badNeighbours
}

/// What a relink pass did, rather than a bare count.
///
/// The caller needs both numbers: `relinked` is the silent repair nobody has to be
/// told about, and `unresolved` is the one that has to surface as "3 songs in this
/// playlist are missing". Returning only the first would force a second query to
/// discover the second.
public struct RelinkReport: Equatable, Sendable {
    /// Entries examined — every live playlist row.
    public var checked = 0
    /// Rewritten to a new Jellyfin id found by content key.
    public var relinked = 0
    /// Previously marked unresolved and resolving again, so the mark was cleared.
    public var recovered = 0
    /// Newly marked unresolved: no id matched their fingerprint.
    public var unresolved = 0

    public var changed: Int { relinked + recovered + unresolved }
}

public extension PlaylistItem {
    /// Stamped onto `jellyfinId` when a relink pass finds no track for the entry.
    ///
    /// The schema has no `unresolved` column and this deliberately does not add one:
    /// the state is a property of the id — "this no longer points anywhere" — and a
    /// migration for it would have to be agreed by every device and the sidecar
    /// before the flag could travel. Living inside a column that already syncs, it
    /// travels for free, and a build that has never heard of the marker simply fails
    /// to resolve the id, which is precisely the situation the entry is in. Jellyfin
    /// item ids are hex GUIDs, so a colon cannot occur in a real one and the marker
    /// can never be mistaken for part of an id.
    static let unresolvedPrefix = "unresolved:"

    var isUnresolved: Bool { jellyfinId.hasPrefix(Self.unresolvedPrefix) }

    /// The id to actually play or look up, marker stripped.
    ///
    /// The last id that did resolve is kept rather than blanked, because the usual
    /// cause of a miss is an unmounted drive or a paused server, and those come back
    /// under the same id.
    var linkedJellyfinId: String {
        isUnresolved ? String(jellyfinId.dropFirst(Self.unresolvedPrefix.count)) : jellyfinId
    }
}

// MARK: - Playlists

public extension CurationStore {
    /// Non-deleted playlists in display order, across every folder.
    ///
    /// Sort keys are generated against *all* playlists rather than per folder, which
    /// is what makes this flat listing meaningful — and a folder's contents are then
    /// simply a subsequence of it, so both orderings come from one key.
    func playlists() throws -> [Playlist] {
        try read { db in
            try Playlist.filter(Column("deleted") == false)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    /// Non-deleted playlists filed directly under `folderId`; `nil` means the root.
    func playlists(inFolder folderId: String?) throws -> [Playlist] {
        try read { db in
            try Playlist.filter(Column("deleted") == false && Column("folderId") == folderId)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    func playlist(_ id: String) throws -> Playlist? {
        let row = try read { db in try Playlist.fetchOne(db, key: id) }
        return row?.deleted == true ? nil : row
    }

    @discardableResult
    func createPlaylist(
        name: String,
        folderId: String? = nil,
        notes: String? = nil,
        now: Millis = Date().millis
    ) throws -> Playlist {
        if let folderId { try requireFolder(folderId) }
        return try record(
            Playlist(
                name: name,
                notes: notes,
                folderId: folderId,
                sortIndex: try nextPlaylistSortIndex(),
                updatedAt: now,
                originDevice: deviceId
            ),
            at: now
        )
    }

    /// Renames in place, leaving every other field as it was.
    ///
    /// The whole row goes into the op even though one field changed, because merging
    /// is per-field on the receiving side: a device that reordered this playlist at
    /// the same time keeps its reorder and takes this name.
    @discardableResult
    func rename(playlist id: String, to name: String, now: Millis = Date().millis) throws -> Playlist {
        var list = try requirePlaylist(id)
        list.name = name
        return try record(list, at: now)
    }

    @discardableResult
    func setNotes(_ notes: String?, on playlistId: String, now: Millis = Date().millis) throws -> Playlist {
        var list = try requirePlaylist(playlistId)
        list.notes = notes
        return try record(list, at: now)
    }

    /// Files a playlist under `folderId`, or at the root when that is `nil`.
    ///
    /// The sort key is regenerated so the playlist lands at the end of its new
    /// folder. Keeping the old key would drop it at whatever point of the
    /// destination its previous neighbours happened to occupy, which looks random to
    /// the person who just dragged it in.
    @discardableResult
    func move(playlist id: String, toFolder folderId: String?, now: Millis = Date().millis) throws -> Playlist {
        var list = try requirePlaylist(id)
        if let folderId { try requireFolder(folderId) }
        list.folderId = folderId
        list.sortIndex = try nextPlaylistSortIndex()
        return try record(list, at: now)
    }

    /// Soft-deletes a playlist **and its items**.
    ///
    /// The items are not optional collateral: rows left behind still match on content
    /// key, so the next relink pass would rewrite them, and any un-delete — or a
    /// device that merges the delete late — would find the playlist whole again. They
    /// go first so that a crash half way through leaves a shortened playlist, which
    /// is recoverable by repeating the delete, rather than a set of orphans that
    /// nothing points at any more.
    func deletePlaylist(_ id: String, now: Millis = Date().millis) throws {
        guard let list = try read({ db in try Playlist.fetchOne(db, key: id) }) else {
            throw PlaylistError.noSuchPlaylist(id)
        }
        // Deleting twice must not mint a second op; the first one already carries the
        // whole story.
        guard !list.deleted else { return }

        // One row and one op per item rather than a single UPDATE: a bulk statement
        // would change rows with no ops behind them, and a change without an op never
        // leaves this device.
        for item in try items(in: id) {
            try record(item, deleted: true, at: now)
        }
        try record(list, deleted: true, at: now)
    }

    /// Repositions a playlist between two of its siblings.
    ///
    /// `nil` on either side means the end: `before:` alone moves it to the top,
    /// `after:` alone to the bottom. Passing neither leaves it where it is — there is
    /// no position to compute from nothing.
    @discardableResult
    func reorderPlaylist(
        _ id: String,
        after: String? = nil,
        before: String? = nil,
        now: Millis = Date().millis
    ) throws -> Playlist {
        var list = try requirePlaylist(id)
        guard after != nil || before != nil else { return list }
        guard after != id, before != id else { throw PlaylistError.badNeighbours }

        let lower = try after.map { try requirePlaylist($0).sortIndex }
        let upper = try before.map { try requirePlaylist($0).sortIndex }
        try Self.checkGap(lower, upper)

        list.sortIndex = FractionalIndex.between(lower, upper)
        return try record(list, at: now)
    }
}

// MARK: - Folders

public extension CurationStore {
    func folders() throws -> [Folder] {
        try read { db in
            try Folder.filter(Column("deleted") == false)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    /// Non-deleted folders directly under `parentId`; `nil` means the root.
    func folders(inParent parentId: String?) throws -> [Folder] {
        try read { db in
            try Folder.filter(Column("deleted") == false && Column("parentId") == parentId)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    func folder(_ id: String) throws -> Folder? {
        let row = try read { db in try Folder.fetchOne(db, key: id) }
        return row?.deleted == true ? nil : row
    }

    @discardableResult
    func createFolder(name: String, parentId: String? = nil, now: Millis = Date().millis) throws -> Folder {
        if let parentId { try requireFolder(parentId) }
        return try record(
            Folder(
                name: name,
                parentId: parentId,
                sortIndex: try nextFolderSortIndex(),
                updatedAt: now,
                originDevice: deviceId
            ),
            at: now
        )
    }

    @discardableResult
    func rename(folder id: String, to name: String, now: Millis = Date().millis) throws -> Folder {
        var folder = try requireFolder(id)
        folder.name = name
        return try record(folder, at: now)
    }

    /// Re-parents a folder, refusing any move that would make it its own ancestor.
    @discardableResult
    func move(folder id: String, toParent parentId: String?, now: Millis = Date().millis) throws -> Folder {
        var folder = try requireFolder(id)
        if let parentId {
            try requireFolder(parentId)
            guard try !ancestryContains(id, startingAt: parentId) else {
                throw PlaylistError.folderCycle(folder: id, under: parentId)
            }
        }
        folder.parentId = parentId
        // Same reasoning as moving a playlist: land at the end of the new parent
        // rather than at an arbitrary point inherited from the old one.
        folder.sortIndex = try nextFolderSortIndex()
        return try record(folder, at: now)
    }

    /// Soft-deletes a folder and promotes everything inside it one level up.
    ///
    /// Cascading was the alternative and is the wrong default: a folder is filing,
    /// not content, so the gesture that removes one reads as "stop organising this
    /// way" and must not destroy playlists that took years to build. Promoting to the
    /// deleted folder's *parent* rather than to the root keeps them where the person
    /// was already looking. Leaving `folderId` pointing at a deleted folder was never
    /// an option: the playlists would exist but appear in no listing, which is a
    /// delete with extra steps. A UI that genuinely wants cascade deletes the
    /// children first.
    func deleteFolder(_ id: String, now: Millis = Date().millis) throws {
        guard let folder = try read({ db in try Folder.fetchOne(db, key: id) }) else {
            throw PlaylistError.noSuchFolder(id)
        }
        guard !folder.deleted else { return }

        for var child in try folders(inParent: id) {
            child.parentId = folder.parentId
            try record(child, at: now)
        }
        for var list in try playlists(inFolder: id) {
            list.folderId = folder.parentId
            try record(list, at: now)
        }
        try record(folder, deleted: true, at: now)
    }

    /// Repositions a folder between two siblings; see `reorderPlaylist`.
    @discardableResult
    func reorderFolder(
        _ id: String,
        after: String? = nil,
        before: String? = nil,
        now: Millis = Date().millis
    ) throws -> Folder {
        var folder = try requireFolder(id)
        guard after != nil || before != nil else { return folder }
        guard after != id, before != id else { throw PlaylistError.badNeighbours }

        let lower = try after.map { try requireFolder($0).sortIndex }
        let upper = try before.map { try requireFolder($0).sortIndex }
        try Self.checkGap(lower, upper)

        folder.sortIndex = FractionalIndex.between(lower, upper)
        return try record(folder, at: now)
    }
}

// MARK: - Items

public extension CurationStore {
    /// Live entries of a playlist, in order.
    func items(in playlistId: String) throws -> [PlaylistItem] {
        try read { db in
            try PlaylistItem.filter(Column("playlistId") == playlistId && Column("deleted") == false)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    /// Counted in SQLite rather than by fetching and counting in Swift — a library
    /// view shows a count beside every playlist, and fetching each one's rows to
    /// print a number is the difference between one query and thousands.
    func itemCount(in playlistId: String) throws -> Int {
        try read { db in
            try PlaylistItem.filter(Column("playlistId") == playlistId && Column("deleted") == false)
                .fetchCount(db)
        }
    }

    /// Appends tracks to the end of a playlist, in the order given.
    ///
    /// A track already present is added again rather than skipped. Apple Music allows
    /// it, and it is genuinely wanted: a set list that plays the same song twice, or
    /// an album added to a mix that already shares one track with it. Deduplicating
    /// would also have to pick which copy to keep on a later relink, and there is no
    /// right answer to that.
    @discardableResult
    func addTracks(_ links: [TrackLink], to playlistId: String, now: Millis = Date().millis) throws -> [PlaylistItem] {
        try requirePlaylist(playlistId)
        return try insert(links, into: playlistId, between: try lastPosition(in: playlistId), and: nil, now: now)
    }

    /// Inserts tracks so the first of them ends up at `index`.
    @discardableResult
    func insertTracks(
        _ links: [TrackLink],
        into playlistId: String,
        at index: Int,
        now: Millis = Date().millis
    ) throws -> [PlaylistItem] {
        try requirePlaylist(playlistId)
        let existing = try items(in: playlistId)
        let target = min(max(index, 0), existing.count)
        return try insert(
            links,
            into: playlistId,
            between: target > 0 ? existing[target - 1].position : nil,
            and: target < existing.count ? existing[target].position : nil,
            now: now
        )
    }

    /// Drag-to-reorder. Writes exactly one row.
    ///
    /// `index` is where the entry ends up, measured in the list with it already taken
    /// out. SwiftUI's `onMove` destination is measured *before* the removal instead,
    /// so a caller forwarding it straight through has to subtract one when the drag
    /// went downwards.
    @discardableResult
    func moveItem(
        _ itemId: String,
        in playlistId: String,
        to index: Int,
        now: Millis = Date().millis
    ) throws -> PlaylistItem {
        var item = try requireItem(itemId)
        guard item.playlistId == playlistId else {
            throw PlaylistError.itemNotInPlaylist(item: itemId, playlist: playlistId)
        }

        let others = try items(in: playlistId).filter { $0.id != itemId }
        let target = min(max(index, 0), others.count)
        let lower = target > 0 ? others[target - 1].position : nil
        let upper = target < others.count ? others[target].position : nil

        // A drag that lands back where it started should not manufacture an op that
        // every other device then has to merge.
        let alreadyAbove = lower.map { $0 < item.position } ?? true
        let alreadyBelow = upper.map { item.position < $0 } ?? true
        if alreadyAbove && alreadyBelow { return item }

        // One row, and only one. Renumbering the neighbours would hand back exactly
        // what the fractional index was chosen to buy — see `FractionalIndex` for
        // what that costs during a concurrent edit.
        item.position = FractionalIndex.between(lower, upper)
        return try record(item, at: now)
    }

    /// Soft-deletes an entry.
    func removeItem(_ itemId: String, now: Millis = Date().millis) throws {
        guard let item = try read({ db in try PlaylistItem.fetchOne(db, key: itemId) }) else {
            throw PlaylistError.noSuchItem(itemId)
        }
        guard !item.deleted else { return }
        try record(item, deleted: true, at: now)
    }
}

// MARK: - Relinking

public extension CurationStore {
    /// Repairs entries whose Jellyfin id stopped resolving, by content key.
    ///
    /// Two closures rather than one because they are two different questions and a
    /// caller may well answer them from two different places: `live` is "does this id
    /// still exist", which a freshly synced library can answer directly, and
    /// `resolve` is "what id does this fingerprint have now", which may need a search.
    ///
    /// An entry that matches nothing is *marked*, never deleted — the file may simply
    /// be on an unmounted drive or a server that is down, and a playlist entry
    /// destroyed for that is gone for good. See `PlaylistItem.isUnresolved` for where
    /// the mark lives.
    @discardableResult
    func relinkItems(
        live: (_ jellyfinId: String) -> Bool,
        resolving resolve: (_ contentKey: String) -> String?,
        now: Millis = Date().millis
    ) throws -> RelinkReport {
        let items = try read { db in
            try PlaylistItem.filter(Column("deleted") == false).fetchAll(db)
        }

        var report = RelinkReport()
        report.checked = items.count

        for var item in items {
            let current = item.linkedJellyfinId

            if live(current) {
                guard item.isUnresolved else { continue }
                item.jellyfinId = current
                try record(item, at: now)
                report.recovered += 1
                continue
            }

            if let replacement = resolve(item.contentKey) {
                // The resolver handing back the id already stored contradicts `live`;
                // trust `live` and leave the row alone rather than writing an op that
                // changes nothing.
                guard replacement != current || item.isUnresolved else { continue }
                item.jellyfinId = replacement
                try record(item, at: now)
                report.relinked += 1
                continue
            }

            guard !item.isUnresolved else { continue }
            item.jellyfinId = PlaylistItem.unresolvedPrefix + current
            try record(item, at: now)
            report.unresolved += 1
        }
        return report
    }

    /// Relinks against the local track cache, which is this device's mirror of what
    /// Jellyfin currently holds. This is the pass to run after a library scan.
    @discardableResult
    func relinkItemsAgainstTrackCache(now: Millis = Date().millis) throws -> RelinkReport {
        let cache = try read { db in try TrackRef.fetchAll(db) }

        // An empty cache means the scan has not run yet, not that the whole library
        // vanished. Without this guard the first launch after an install would mark
        // every entry in every playlist unresolved.
        guard !cache.isEmpty else { return RelinkReport() }

        let live = Set(cache.map(\.jellyfinId))
        var byContentKey: [String: String] = [:]
        // Last one wins on a duplicate fingerprint: two files that normalise to the
        // same key are the same recording twice over, so either id is a correct
        // answer and there is nothing to choose between them.
        for track in cache { byContentKey[track.contentKey] = track.jellyfinId }

        return try relinkItems(
            live: { live.contains($0) },
            resolving: { byContentKey[$0] },
            now: now
        )
    }
}

// MARK: - Internals

private extension CurationStore {
    @discardableResult
    func requirePlaylist(_ id: String) throws -> Playlist {
        guard let list = try playlist(id) else { throw PlaylistError.noSuchPlaylist(id) }
        return list
    }

    @discardableResult
    func requireFolder(_ id: String) throws -> Folder {
        guard let folder = try folder(id) else { throw PlaylistError.noSuchFolder(id) }
        return folder
    }

    func requireItem(_ id: String) throws -> PlaylistItem {
        guard let item = try read({ db in try PlaylistItem.fetchOne(db, key: id) }), !item.deleted else {
            throw PlaylistError.noSuchItem(id)
        }
        return item
    }

    /// Whether `folderId` lies on the parent chain that starts at `startId`.
    ///
    /// The visited set is not defensive padding. This guard stops a local move from
    /// creating a cycle, but one can still *arrive*: two devices, offline, moving A
    /// under B and B under A each see a legal move, and per-field last-writer-wins
    /// keeps both edges. So this walk has to terminate on a graph it did not build,
    /// and a repeat visit is reported as a cycle because that is what it is.
    func ancestryContains(_ folderId: String, startingAt startId: String) throws -> Bool {
        try read { db in
            var cursor: String? = startId
            var seen: Set<String> = []
            while let id = cursor {
                if id == folderId { return true }
                guard seen.insert(id).inserted else { return true }
                cursor = try Folder.fetchOne(db, key: id)?.parentId
            }
            return false
        }
    }

    func nextPlaylistSortIndex() throws -> String {
        let last = try read { db in
            try Playlist.filter(Column("deleted") == false)
                .order(Column("sortIndex").desc)
                .fetchOne(db)
        }
        return FractionalIndex.between(last?.sortIndex, nil)
    }

    func nextFolderSortIndex() throws -> String {
        let last = try read { db in
            try Folder.filter(Column("deleted") == false)
                .order(Column("sortIndex").desc)
                .fetchOne(db)
        }
        return FractionalIndex.between(last?.sortIndex, nil)
    }

    func lastPosition(in playlistId: String) throws -> String? {
        try read { db in
            try PlaylistItem.filter(Column("playlistId") == playlistId && Column("deleted") == false)
                .order(Column("position").desc)
                .fetchOne(db)?.position
        }
    }

    func insert(
        _ links: [TrackLink],
        into playlistId: String,
        between lower: String?,
        and upper: String?,
        now: Millis
    ) throws -> [PlaylistItem] {
        var created: [PlaylistItem] = []
        for (link, position) in zip(links, Self.positions(count: links.count, between: lower, and: upper)) {
            created.append(try record(
                PlaylistItem(
                    playlistId: playlistId,
                    jellyfinId: link.jellyfinId,
                    contentKey: link.contentKey,
                    position: position,
                    updatedAt: now,
                    originDevice: deviceId
                ),
                at: now
            ))
        }
        return created
    }

    static func positions(count: Int, between lower: String?, and upper: String?) -> [String] {
        guard count > 0 else { return [] }
        // Appending has a cheap path in FractionalIndex — it counts upwards instead
        // of bisecting, which is what keeps a thousand appends short instead of 167
        // characters each. Worth taking whenever there is nothing above.
        guard let upper else { return FractionalIndex.sequence(after: lower, count: count) }

        // Bulk-inserting into the middle has no such trick: each key bisects what is
        // left of the gap, so a run of n costs roughly n characters on the last one.
        // Acceptable because it is bounded by the run length and rare — dropping a
        // whole album into the middle of a playlist, not the thing that happens on
        // every add.
        var keys: [String] = []
        var previous = lower
        for _ in 0..<count {
            let key = FractionalIndex.between(previous, upper)
            keys.append(key)
            previous = key
        }
        return keys
    }

    static func checkGap(_ lower: String?, _ upper: String?) throws {
        // FractionalIndex asserts on this, and asserts are compiled out of release
        // builds — where the same call quietly returns a key outside the gap the
        // caller asked for, corrupting the order for good. Checking turns that into
        // an error the UI can ignore.
        if let lower, let upper, lower >= upper { throw PlaylistError.badNeighbours }
    }
}
