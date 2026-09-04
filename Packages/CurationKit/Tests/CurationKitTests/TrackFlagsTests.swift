import Foundation
import GRDB
import Testing
@testable import CurationKit

@Suite("Taste flags")
struct TrackFlagsTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    private func cache(_ store: CurationStore, _ ids: [String]) throws {
        try store.writeLocal { db in
            for id in ids {
                try TrackRef(jellyfinId: id, contentKey: "key-\(id)", title: id, artist: "a", album: "b", lastSeenAt: 0).insert(db)
            }
        }
    }

    @Test("setting a flag mints one row per track and records an op")
    func setMints() throws {
        let store = try store()
        try store.setNotInterested(true, on: "t1", contentKey: "k1", now: 10)
        try store.setDontCount(true, on: "t1", contentKey: "k1", now: 11)
        let flags = try #require(try store.flags(for: "t1"))
        #expect(flags.notInterested && flags.dontCount)
        #expect(try store.read { try TrackFlags.fetchCount($0) } == 1)
        let ops = try store.pendingOps().filter { $0.entity == "trackFlags" }
        #expect(ops.count == 2)
        #expect(ops.allSatisfy { $0.entityId == flags.id })
    }

    @Test("clearing both flags deletes the row rather than keeping an empty one")
    func emptyRowGoes() throws {
        let store = try store()
        try store.setNotInterested(true, on: "t1", contentKey: "k1", now: 10)
        try store.setNotInterested(false, on: "t1", contentKey: "k1", now: 20)
        #expect(try store.flags(for: "t1") == nil)
        let last = try #require(try store.pendingOps().last)
        #expect(last.operation == Op.Kind.delete.rawValue)
    }

    @Test("a flag set again after deletion reuses the row's id")
    func reuseId() throws {
        let store = try store()
        try store.setNotInterested(true, on: "t1", contentKey: "k1", now: 10)
        let first = try #require(try store.flags(for: "t1")).id
        try store.setNotInterested(false, on: "t1", contentKey: "k1", now: 20)
        try store.setDontCount(true, on: "t1", contentKey: "k1", now: 30)
        #expect(try store.flags(for: "t1")?.id == first)
    }

    @Test("not-interested tracks fall out of every smart playlist")
    func excludedFromRules() throws {
        let store = try store()
        try cache(store, ["a", "b", "c"])
        try store.setNotInterested(true, on: "b", contentKey: "key-b", now: 10)
        let everything = try SmartRules(match: .all, rules: [])
        #expect(Set(try store.evaluate(everything)) == ["a", "c"])
        try store.setDontCount(true, on: "c", contentKey: "key-c", now: 11)
        // dontCount alone does not hide a track.
        #expect(Set(try store.evaluate(everything)) == ["a", "c"])
    }

    @Test("notInterested(among:) answers for a list, in chunks")
    func among() throws {
        let store = try store()
        let ids = (0..<900).map { "t\($0)" }
        try store.setNotInterested(true, on: "t5", contentKey: "k", now: 1)
        try store.setNotInterested(true, on: "t850", contentKey: "k", now: 1)
        #expect(try store.notInterested(among: ids) == ["t5", "t850"])
        #expect(try store.notInterested(among: []).isEmpty)
    }

    @Test("flaggedTracks lists them newest first with what the cache knows")
    func listing() throws {
        let store = try store()
        try cache(store, ["a"])
        try store.setDontCount(true, on: "a", contentKey: "key-a", now: 1)
        try store.setNotInterested(true, on: "zz", contentKey: "key-zz", now: 2)
        let listed = try store.flaggedTracks()
        #expect(listed.map(\.flags.jellyfinId) == ["zz", "a"])
        #expect(listed[1].track?.title == "a")
        #expect(listed[0].track == nil)
    }
}

@Suite("Holding entities the server does not accept")
struct HeldEntityTests {
    /// A transport that records what it was sent and accepts all of it.
    actor Recorder: SyncTransport, SyncCapabilityTransport {
        var pushed: [String] = []
        var accepted: Set<String>
        init(accepted: Set<String>) { self.accepted = accepted }
        func setAccepted(_ set: Set<String>) { accepted = set }
        func push(_ request: PushRequest) async throws -> PushResponse {
            pushed.append(contentsOf: request.ops.map(\.entity))
            return PushResponse(accepted: request.ops.map(\.opId), rejected: [], cursor: nil)
        }
        func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse {
            PullResponse(ops: [], cursor: cursor ?? PullCursor(0), hasMore: false)
        }
        func acceptedEntities() async throws -> Set<String> { accepted }
    }

    private func seeded() throws -> CurationStore {
        let store = try CurationStore.inMemory(deviceId: "phone")
        _ = try store.createPlaylist(name: "p", now: 5)
        try store.setNotInterested(true, on: "t1", contentKey: "k1", now: 6)
        return store
    }

    @Test("a flag op waits while the server does not list track_flags; the playlist still goes")
    func heldUntilAdvertised() async throws {
        let store = try seeded()
        let transport = Recorder(accepted: ["playlists", "likes"])
        let engine = SyncEngine(store: store, transport: transport, capabilities: transport)
        _ = try await engine.sync()
        #expect(await transport.pushed == ["playlists"])
        #expect(await engine.heldEntities == ["trackFlags"])
        #expect(try store.pendingOps().map(\.entity) == ["trackFlags"])
        #expect(try store.quarantinedOps().isEmpty)

        await transport.setAccepted(["playlists", "track_flags"])
        _ = try await engine.sync()
        #expect(await transport.pushed == ["playlists", "track_flags"])
        #expect(await engine.heldEntities.isEmpty)
        #expect(try store.pendingOps().isEmpty)
    }

    @Test("no capability transport at all means the new entity is held, never refused")
    func heldWithoutCapabilities() async throws {
        let store = try seeded()
        let transport = Recorder(accepted: [])
        let engine = SyncEngine(store: store, transport: transport)
        _ = try await engine.sync()
        #expect(await transport.pushed == ["playlists"])
        #expect(try store.pendingOps().map(\.entity) == ["trackFlags"])
    }
}
