import Foundation
import Testing
@testable import CurationKit

/// Creating and repairing the built-in smart playlists (`ensureBuiltInPlaylists`).
@Suite("Built-in playlists in the store")
struct BuiltInPlaylistStoreTests {
    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    @Test("each is made in one write, with its rules")
    func madeWithRules() throws {
        let store = try store()
        #expect(try store.ensureBuiltInPlaylists(now: 1_000) == BuiltInPlaylist.allCases)
        let ops = try store.pendingOps()
        #expect(ops.count == BuiltInPlaylist.allCases.count, "one op each, the row and its rules together")
        for built in BuiltInPlaylist.allCases {
            let row = try #require(try store.playlist(built.id))
            #expect(row.isSmart)
            #expect(try row.smartRuleSet() == built.rules)
        }
        #expect(try store.ensureBuiltInPlaylists(now: 2_000).isEmpty, "nothing to write the second time")
    }

    /// What another device's two writes at one instant left behind: the row under the
    /// built-in's id, made plain because its rules lost the merge's tie.
    @Test("one that lost its rules gets them back")
    func repaired() throws {
        let store = try store()
        let plain = Playlist(
            id: BuiltInPlaylist.heavyRotation.id, name: "Heavy Rotation", sortIndex: "W",
            updatedAt: 500, originDevice: "desk"
        )
        try store.record(plain, at: 500)
        #expect(try store.ensureBuiltInPlaylists(now: 1_000).contains(.heavyRotation))
        let row = try #require(try store.playlist(BuiltInPlaylist.heavyRotation.id))
        #expect(row.isSmart)
        #expect(try row.smartRuleSet() == BuiltInPlaylist.heavyRotation.rules)
    }

    @Test("one deleted stays deleted")
    func deletedStays() throws {
        let store = try store()
        try store.ensureBuiltInPlaylists(now: 1_000)
        let row = try #require(try store.playlist(BuiltInPlaylist.rediscover.id))
        try store.record(row, deleted: true, at: 2_000)
        #expect(try store.ensureBuiltInPlaylists(now: 3_000).isEmpty)
        #expect(try store.playlist(BuiltInPlaylist.rediscover.id) == nil)
    }
}
