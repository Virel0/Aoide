import Foundation

/// What a merge put in the playlist it merged into.
public struct MergeReport: Equatable, Sendable {
    /// Songs from the library that were added.
    public var added = 0
    /// Songs still to arrive that were added, waiting on their requests.
    public var waiting = 0

    public var total: Int { added + waiting }

    public init(added: Int = 0, waiting: Int = 0) {
        self.added = added
        self.waiting = waiting
    }
}

public enum PlaylistMergeError: Error, Equatable, Sendable {
    /// A smart playlist's songs come from its rules, so there is nothing to add to.
    case targetIsSmart
    case sameSourceAndTarget
}

public extension CurationStore {
    /// Copies one playlist's songs onto the end of another, in the source's order.
    ///
    /// Songs the target already holds are skipped, and so is a second copy within
    /// the source: merging two playlists that share songs should give one of each,
    /// not a list that plays them twice. A song counts as the same by its track id
    /// or its fingerprint, so a copy relinked after a rescan still matches; a song
    /// still to arrive matches by its request, or by title and artist when it has
    /// none.
    ///
    /// A smart source gives the songs its rules match now, as a manual copy. The
    /// source itself is never changed: deleting it is a separate choice.
    ///
    /// - Throws: `PlaylistError.noSuchPlaylist` when either playlist is gone,
    ///   `PlaylistMergeError` when the target is smart or is the source, and any
    ///   database or rule-evaluation error.
    @discardableResult
    func merge(playlist sourceId: String, into targetId: String, now: Millis = Date().millis) throws -> MergeReport {
        guard sourceId != targetId else { throw PlaylistMergeError.sameSourceAndTarget }
        guard let source = try playlist(sourceId) else { throw PlaylistError.noSuchPlaylist(sourceId) }
        guard let target = try playlist(targetId) else { throw PlaylistError.noSuchPlaylist(targetId) }
        guard !target.isSmart else { throw PlaylistMergeError.targetIsSmart }

        let existing = try items(in: targetId)
        var seen = MergeKeys(existing)
        let incoming = try mergeEntries(of: source, now: now).filter { seen.insert($0) }
        let positions = FractionalIndex.sequence(after: existing.last?.position, count: incoming.count)

        var report = MergeReport()
        for (entry, position) in zip(incoming, positions) {
            try record(entry.item(in: targetId, at: position, now: now, device: deviceId), at: now)
            if entry.isWaiting { report.waiting += 1 } else { report.added += 1 }
        }
        return report
    }

    /// The source's songs as they would be copied: its entries, or its rule matches.
    private func mergeEntries(of source: Playlist, now: Millis) throws -> [MergeEntry] {
        guard source.isSmart else {
            return try items(in: source.id).compactMap(MergeEntry.init)
        }
        let ids = try resolve(playlist: source, asOf: now)
        let cached = try cachedTracks(jellyfinIds: ids)
        return ids.compactMap { id in
            cached[id].map { MergeEntry.track(id: $0.jellyfinId, contentKey: $0.contentKey) }
        }
    }
}

/// One song on its way into the target.
private enum MergeEntry {
    case track(id: String, contentKey: String)
    case waiting(PendingSong)

    init?(_ item: PlaylistItem) {
        if let id = item.jellyfinId, let key = item.contentKey {
            self = .track(id: id, contentKey: key)
        } else if let pending = item.pending {
            self = .waiting(pending)
        } else {
            return nil
        }
    }

    var isWaiting: Bool { if case .waiting = self { true } else { false } }

    func item(in playlistId: String, at position: String, now: Millis, device: String) -> PlaylistItem {
        switch self {
        case .track(let id, let key):
            PlaylistItem(
                playlistId: playlistId, jellyfinId: id, contentKey: key,
                position: position, updatedAt: now, originDevice: device
            )
        case .waiting(let song):
            PlaylistItem(playlistId: playlistId, pending: song, position: position, updatedAt: now, originDevice: device)
        }
    }
}

/// The songs a playlist already holds, by every way two copies can be the same.
private struct MergeKeys {
    private var tracks: Set<String> = []
    private var fingerprints: Set<String> = []
    private var waiting: Set<String> = []

    init(_ items: [PlaylistItem]) {
        for entry in items.compactMap(MergeEntry.init) { _ = insert(entry) }
    }

    /// Notes the song, and says whether it was new.
    mutating func insert(_ entry: MergeEntry) -> Bool {
        switch entry {
        case .waiting(let song):
            return waiting.insert(Self.key(song)).inserted
        case .track(let rawId, let key):
            // A relink miss marks the id but keeps it, so the marked copy and a
            // live one are still the same song.
            let id = rawId.hasPrefix(PlaylistItem.unresolvedPrefix)
                ? String(rawId.dropFirst(PlaylistItem.unresolvedPrefix.count)) : rawId
            let known = tracks.contains(id) || fingerprints.contains(key)
            tracks.insert(id)
            fingerprints.insert(key)
            return !known
        }
    }

    private static func key(_ song: PendingSong) -> String {
        if let requestId = song.requestId { return "request:\(requestId)" }
        return "song:\(folded(song.title))|\(folded(song.artist ?? ""))"
    }

    /// Case and accents ignored, so "Beyoncé" and "beyonce" are one artist.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
