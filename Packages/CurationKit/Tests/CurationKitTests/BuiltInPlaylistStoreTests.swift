import Foundation
import Testing
@testable import CurationKit

/// Creating, repairing and moving the built-in smart playlists (`ensureBuiltInPlaylists`).
@Suite("Built-in playlists in the store")
struct BuiltInPlaylistStoreTests {
    private let user = "7"

    private func store() throws -> CurationStore { try .inMemory(deviceId: "phone") }

    @Test("each is made in one write, with its rules, under the user's own id")
    func madeWithRules() throws {
        let store = try store()
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 1_000) == BuiltInPlaylist.allCases)
        let ops = try store.pendingOps()
        #expect(ops.count == BuiltInPlaylist.allCases.count, "one op each, the row and its rules together")
        for built in BuiltInPlaylist.allCases {
            let row = try #require(try store.playlist(built.id(forUser: user)))
            #expect(row.isSmart)
            #expect(try row.smartRuleSet() == built.rules)
            #expect(try store.playlistRowExists(built.legacyId) == false)
        }
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 2_000).isEmpty, "nothing to write the second time")
    }

    /// What another device's two writes at one instant left behind: the row under the
    /// built-in's id, made plain because its rules lost the merge's tie.
    @Test("one that lost its rules gets them back")
    func repaired() throws {
        let store = try store()
        let id = BuiltInPlaylist.heavyRotation.id(forUser: user)
        let plain = Playlist(id: id, name: "Heavy Rotation", sortIndex: "W", updatedAt: 500, originDevice: "desk")
        try store.record(plain, at: 500)
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 1_000).contains(.heavyRotation))
        let row = try #require(try store.playlist(id))
        #expect(row.isSmart)
        #expect(try row.smartRuleSet() == BuiltInPlaylist.heavyRotation.rules)
    }

    @Test("one deleted stays deleted")
    func deletedStays() throws {
        let store = try store()
        let id = BuiltInPlaylist.rediscover.id(forUser: user)
        try store.ensureBuiltInPlaylists(userId: user, now: 1_000)
        let row = try #require(try store.playlist(id))
        try store.record(row, deleted: true, at: 2_000)
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 3_000).isEmpty)
        #expect(try store.playlist(id) == nil)
    }

    /// Two users on one server: under one shared id, Melete gave it to whoever
    /// synced first and refused it to the other (Melete#324).
    @Test("two users' ids differ")
    func perUser() {
        for built in BuiltInPlaylist.allCases {
            #expect(built.id(forUser: "1") != built.id(forUser: "2"))
            #expect(BuiltInPlaylist(playlistId: built.id(forUser: "1")) == built)
            #expect(BuiltInPlaylist(playlistId: built.legacyId) == built)
        }
        #expect(BuiltInPlaylist(playlistId: "my-own") == nil)
    }

    @Test("one under the old shared id moves to the user's, keeping its name, and the old one is deleted")
    func moved() throws {
        let store = try store()
        let built = BuiltInPlaylist.rediscover
        let old = try store.createPlaylist(
            name: "Old Favourites", notes: built.notes, id: built.legacyId, smartRules: built.rules, now: 500
        )
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 1_000) == BuiltInPlaylist.allCases)
        let row = try #require(try store.playlist(built.id(forUser: user)))
        #expect(row.name == "Old Favourites")
        #expect(row.sortIndex == old.sortIndex)
        #expect(try row.smartRuleSet() == built.rules)
        #expect(try store.playlist(built.legacyId) == nil, "the old one is deleted")
        let deletes = try store.pendingOps().filter { $0.entityId == built.legacyId && $0.operation == "delete" }
        #expect(deletes.count == 1)
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 2_000).isEmpty)
    }

    @Test("one deleted under the old shared id isn't made again")
    func deletedBeforeTheMove() throws {
        let store = try store()
        let built = BuiltInPlaylist.heavyRotation
        try store.createPlaylist(name: built.name, notes: built.notes, id: built.legacyId, smartRules: built.rules, now: 500)
        try store.deletePlaylist(built.legacyId, now: 600)
        #expect(try store.ensureBuiltInPlaylists(userId: user, now: 1_000) == [.rediscover])
        #expect(try store.playlistRowExists(built.id(forUser: user)) == false)
    }
}
