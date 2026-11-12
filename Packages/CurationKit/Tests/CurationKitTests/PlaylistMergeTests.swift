import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Merging playlists")
struct PlaylistMergeTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func links(_ ids: [String]) -> [TrackLink] {
        ids.map { TrackLink(jellyfinId: $0, contentKey: "key-\($0)") }
    }

    private func ids(_ store: CurationStore, _ playlistId: String) throws -> [String?] {
        try store.items(in: playlistId).map(\.jellyfinId)
    }

    @Test("adds the source's songs to the end, in order, skipping ones already there")
    func appendsNewSongsInOrder() throws {
        let store = try store()
        let source = try store.createPlaylist(name: "Source", now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)
        try store.addTracks(links(["c", "a", "d", "b"]), to: source.id, now: 1_000)
        try store.addTracks(links(["a", "b"]), to: target.id, now: 1_000)

        let report = try store.merge(playlist: source.id, into: target.id, now: 2_000)

        #expect(report == MergeReport(added: 2, waiting: 0))
        #expect(try ids(store, target.id) == ["a", "b", "c", "d"])
        #expect(try ids(store, source.id) == ["c", "a", "d", "b"])
    }

    @Test("a song twice in the source lands once")
    func sourceDuplicatesLandOnce() throws {
        let store = try store()
        let source = try store.createPlaylist(name: "Source", now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)
        try store.addTracks(links(["a", "b", "a"]), to: source.id, now: 1_000)

        try store.merge(playlist: source.id, into: target.id, now: 2_000)

        #expect(try ids(store, target.id) == ["a", "b"])
    }

    @Test("the same song under a new id after a rescan still counts as there")
    func matchesByFingerprint() throws {
        let store = try store()
        let source = try store.createPlaylist(name: "Source", now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)
        try store.addTracks([TrackLink(jellyfinId: "new-id", contentKey: "same")], to: source.id, now: 1_000)
        try store.addTracks([TrackLink(jellyfinId: "old-id", contentKey: "same")], to: target.id, now: 1_000)

        let report = try store.merge(playlist: source.id, into: target.id, now: 2_000)

        #expect(report.total == 0)
        #expect(try ids(store, target.id) == ["old-id"])
    }

    @Test("waiting songs come too, once per request")
    func carriesWaitingSongs() throws {
        let store = try store()
        let source = try store.createPlaylist(name: "Source", now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)
        let lanterns = PendingSong(requestId: 12, title: "Paper Lanterns", artist: "The Quiet Hours")
        let tide = PendingSong(requestId: nil, title: "Low Tide", artist: "Harbour")
        try store.addTracks(links(["a"]), to: source.id, now: 1_000)
        try store.addPendingSong(lanterns, to: source.id, now: 1_000)
        try store.addPendingSong(tide, to: source.id, now: 1_000)
        try store.addPendingSong(lanterns, to: target.id, now: 1_000)

        let report = try store.merge(playlist: source.id, into: target.id, now: 2_000)

        #expect(report == MergeReport(added: 1, waiting: 1))
        let merged = try store.items(in: target.id)
        #expect(merged.map(\.pending?.title) == ["Paper Lanterns", nil, "Low Tide"])
        #expect(merged[1].jellyfinId == "a")
    }

    @Test("a smart playlist gives the songs its rules match now")
    func smartSourceIsASnapshot() throws {
        let store = try store()
        try store.writeLocal { db in
            for (id, genre) in [("jazz-1", "Jazz"), ("rock-1", "Rock"), ("jazz-2", "Jazz")] {
                try TrackRef(
                    jellyfinId: id, contentKey: "key-\(id)", title: id, artist: "a", album: "b",
                    genres: [genre], lastSeenAt: 0
                ).insert(db)
            }
        }
        let rules = try SmartRules(rules: [SmartRule(field: .genre, op: .contains, value: .text("Jazz"))])
        let smart = try store.createPlaylist(name: "Jazz", smartRules: rules, now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)

        let report = try store.merge(playlist: smart.id, into: target.id, now: 2_000)

        #expect(report.added == 2)
        #expect(Set(try ids(store, target.id).compactMap { $0 }) == ["jazz-1", "jazz-2"])
        #expect(try store.items(in: target.id).allSatisfy { $0.contentKey == "key-\($0.jellyfinId ?? "")" })
    }

    @Test("a smart playlist can't be merged into, nor a playlist into itself")
    func refusesBadTargets() throws {
        let store = try store()
        let list = try store.createPlaylist(name: "List", now: 1_000)
        let rules = try SmartRules(rules: [SmartRule(field: .genre, op: .contains, value: .text("Jazz"))])
        let smart = try store.createPlaylist(name: "Jazz", smartRules: rules, now: 1_000)

        #expect(throws: PlaylistMergeError.targetIsSmart) { try store.merge(playlist: list.id, into: smart.id) }
        #expect(throws: PlaylistMergeError.sameSourceAndTarget) { try store.merge(playlist: list.id, into: list.id) }
    }

    @Test("every added song is a change that syncs")
    func recordsOps() throws {
        let store = try store()
        let source = try store.createPlaylist(name: "Source", now: 1_000)
        let target = try store.createPlaylist(name: "Target", now: 1_000)
        try store.addTracks(links(["a", "b"]), to: source.id, now: 1_000)
        let before = try store.pendingOps().count

        try store.merge(playlist: source.id, into: target.id, now: 2_000)

        #expect(try store.pendingOps().count == before + 2)
    }
}
