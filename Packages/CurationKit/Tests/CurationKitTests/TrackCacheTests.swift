import Foundation
import GRDB
import Testing
@testable import CurationKit

/// The local library mirror, and the two things that go wrong when nothing ever takes
/// a row out of it.
///
/// Every other test here seeds the cache with only the ids it wants the relink pass to
/// find. The app cannot: `LocalPlaylistStore.add` caches a song on the way into a
/// playlist and the recorder caches every song played, so by the time a rescan happens
/// the retired ids are already sitting in the table — and a relink that asks the cache
/// "is this id still live" gets yes for all of them. These tests run the real sequence.
@Suite("The track cache and the index that fills it")
struct TrackCacheTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func track(_ id: String, key: String, seenAt: Millis) -> TrackRef {
        TrackRef(
            jellyfinId: id,
            contentKey: key,
            title: id,
            artist: "Artist",
            album: "Album",
            durationMs: 200_000,
            lastSeenAt: seenAt
        )
    }

    // MARK: - Pruning

    @Test("a pass drops only what it did not see")
    func pruneKeepsWhatTheScanReturned() throws {
        let store = try store()
        try store.cacheTracks([
            track("kept", key: "k1", seenAt: 100),
            track("retired", key: "k2", seenAt: 100)
        ])

        // The second pass starts at 200 and re-saves only "kept".
        try store.cacheTracks([track("kept", key: "k1", seenAt: 250)])
        #expect(try store.pruneTracks(notSeenSince: 200) == 1)

        #expect(try store.cachedTrackCount() == 1)
        #expect(try store.cachedTracks(jellyfinIds: ["kept", "retired"]).keys.sorted() == ["kept"])
    }

    @Test("pruning against a cutoff nothing predates removes nothing")
    func pruneIsNotADelete() throws {
        let store = try store()
        try store.cacheTracks([track("a", key: "k1", seenAt: 300), track("b", key: "k2", seenAt: 300)])
        #expect(try store.pruneTracks(notSeenSince: 300) == 0)
        #expect(try store.cachedTrackCount() == 2)
    }

    /// The reason it is a hard `DELETE`: this table is local, rebuilt by each device
    /// from its own connection, and an op for it would be a row every other device
    /// already knows and cannot use.
    @Test("pruning writes no op")
    func pruningIsLocal() throws {
        let store = try store()
        try store.cacheTracks([track("gone", key: "k", seenAt: 1)])
        let before = try store.pendingOps().count
        #expect(try store.pruneTracks(notSeenSince: 2) == 1)
        #expect(try store.pendingOps().count == before)
    }

    // MARK: - The sequence that was broken

    /// The scenario the content key exists for, run the way the app runs it.
    ///
    /// Jellyfin ids are derived per file, so moving the music folder and rescanning
    /// mints a new id for every song. Without the prune the retired ids are still in
    /// the cache, `live` answers yes for all of them, and the repair reports nothing
    /// done while every row on the playlist screen renders as unavailable — which is
    /// exactly the failure the repair was written to prevent.
    @Test("a rescan is only repaired once the retired ids leave the cache")
    func relinkNeedsAPrunedCache() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "Road", now: 0)

        // Adding to a playlist caches the song, which is how the old ids get in.
        try store.cacheTracks([
            track("old-1", key: "k1", seenAt: 100),
            track("old-2", key: "k2", seenAt: 100)
        ])
        try store.addTracks(
            [TrackLink(jellyfinId: "old-1", contentKey: "k1"), TrackLink(jellyfinId: "old-2", contentKey: "k2")],
            to: list.id,
            now: 100
        )

        // The rescan: an index pass beginning at 200 writes the new ids beside the old.
        try store.cacheTracks([
            track("new-1", key: "k1", seenAt: 250),
            track("new-2", key: "k2", seenAt: 250)
        ])

        // Relinking here is the bug: four cached ids, all of them "live".
        #expect(try store.relinkItemsAgainstTrackCache(now: 300).changed == 0)
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["old-1", "old-2"])

        // With the pass's own cutoff applied first, the same call repairs both rows.
        #expect(try store.pruneTracks(notSeenSince: 200) == 2)
        let report = try store.relinkItemsAgainstTrackCache(now: 300)
        #expect(report == RelinkReport(checked: 2, relinked: 2, recovered: 0, unresolved: 0))
        #expect(try store.items(in: list.id).map(\.jellyfinId) == ["new-1", "new-2"])
        #expect(try store.items(in: list.id).allSatisfy { !$0.isUnresolved })
    }

    /// A smart playlist's universe is this table, so a cache holding both generations
    /// answers every rule with twice the library — half of it ids the server will not
    /// resolve, which draw as "Unavailable right now".
    @Test("a doubled cache doubles every smart playlist until it is pruned")
    func staleIdsPolluteTheUniverse() throws {
        let store = try store()
        try store.cacheTracks([track("old", key: "k", seenAt: 100)])
        try store.append(PlayEvent(
            jellyfinId: "old",
            contentKey: "k",
            startedAt: 150,
            endedAt: 150 + 200_000,
            msPlayed: 200_000,
            completed: true,
            source: .album,
            originDevice: "phone"
        ))
        try store.cacheTracks([track("new", key: "k", seenAt: 250)])

        let everything = try SmartRules(rules: [])
        #expect(try store.evaluate(everything, asOf: 300).sorted() == ["new", "old"])

        #expect(try store.pruneTracks(notSeenSince: 200) == 1)
        #expect(try store.evaluate(everything, asOf: 300) == ["new"])
    }

    // MARK: - "Has the index ever run"

    /// The question the automatic index asks. It used to ask whether the cache was
    /// empty, which is a different question with a different answer: the recorder
    /// writes a `track` row for every song *started*, so one play is enough to make
    /// the cache non-empty and stop the index ever running.
    @Test("a cache with rows in it has still never been indexed")
    func indexMarkIsNotRowCount() throws {
        let store = try store()
        try store.cacheTracks([track("played-once", key: "k", seenAt: 5)])

        #expect(try store.cachedTrackCount() == 1)
        #expect(try store.libraryIndexedAt() == nil)

        try store.recordLibraryIndex(at: 1_700_000_000_000)
        #expect(try store.libraryIndexedAt() == 1_700_000_000_000)
    }

    @Test("the mark is overwritten, not appended to")
    func indexMarkIsSingular() throws {
        let store = try store()
        try store.recordLibraryIndex(at: 1)
        try store.recordLibraryIndex(at: 2)
        #expect(try store.libraryIndexedAt() == 2)
    }

    /// It shares a table with the sync cursor, and the two must not read each other.
    @Test("the index mark and the sync cursor are separate keys")
    func indexMarkDoesNotClobberTheCursor() throws {
        let store = try store()
        try store.setSyncCursor("cursor-42")
        try store.recordLibraryIndex(at: 9)

        #expect(try store.syncCursor() == "cursor-42")
        #expect(try store.libraryIndexedAt() == 9)
    }
}
