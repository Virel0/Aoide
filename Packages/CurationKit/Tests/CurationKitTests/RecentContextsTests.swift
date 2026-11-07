import Foundation
import Testing
@testable import CurationKit

@Suite("Recent contexts")
struct RecentContextsTests {
    private func album(_ id: String, at t: Millis) -> RecentContext {
        RecentContext(kind: .album, id: id, name: "Album \(id)", lastOpened: t)
    }

    @Test("newest first, and opening something again moves it to the front")
    func order() {
        var list = RecentContextList()
        list.remember(album("a", at: 1))
        list.remember(album("b", at: 2))
        list.remember(album("a", at: 3))
        #expect(list.contexts.map(\.id) == ["a", "b"])
        #expect(list.contexts.first?.lastOpened == 3)
    }

    @Test("the same id under a different kind is a different thing")
    func kinds() {
        var list = RecentContextList()
        list.remember(album("x", at: 1))
        list.remember(RecentContext(kind: .jellyfinPlaylist, id: "x", name: "List", lastOpened: 2))
        #expect(list.contexts.count == 2)
    }

    @Test("bounded, dropping the oldest")
    func capacity() {
        var list = RecentContextList()
        for i in 0..<(RecentContextList.capacity + 5) { list.remember(album("\(i)", at: Millis(i))) }
        #expect(list.contexts.count == RecentContextList.capacity)
        #expect(list.contexts.first?.id == "\(RecentContextList.capacity + 4)")
        #expect(list.contexts.last?.id == "5")
    }

    @Test("latest takes from the front")
    func latest() {
        var list = RecentContextList()
        for i in 0..<10 { list.remember(album("\(i)", at: Millis(i))) }
        #expect(list.latest(6).map(\.id) == ["9", "8", "7", "6", "5", "4"])
        #expect(list.latest(0).isEmpty)
    }
}

@Suite("Built-in playlists")
struct BuiltInPlaylistTests {
    @Test("ids are fixed and never collide")
    func ids() {
        let ids = BuiltInPlaylist.allCases.map { $0.id(forUser: "1") }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("builtin:") })
    }

    /// If `SmartRule` ever stops accepting one of these rules, this fails, rather
    /// than the app when it creates the playlist.
    @Test("every built-in's rules pass validation", arguments: BuiltInPlaylist.allCases)
    func rulesBuild(_ playlist: BuiltInPlaylist) throws {
        let rules = try playlist.rules
        #expect(!rules.rules.isEmpty)
    }

    /// Pinned as JSON with sorted keys so the desktop can carry the same rules
    /// verbatim; change this and change the desktop's copy.
    @Test("rules are exactly the agreed ones", arguments: BuiltInPlaylist.allCases)
    func rules(_ playlist: BuiltInPlaylist) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(playlist.rules), as: UTF8.self)
        let expected: String = switch playlist {
        case .rediscover:
            #"{"limit":40,"match":"all","rules":[{"field":"last_played","op":"notInTheLast","value":"-6m"},{"field":"play_count","op":"greaterThan","value":2}],"sort":{"dir":"desc","field":"play_count"}}"#
        case .heavyRotation:
            #"{"limit":25,"match":"all","rules":[{"field":"last_played","op":"inTheLast","value":"-1m"},{"field":"play_count","op":"greaterThan","value":1}],"sort":{"dir":"desc","field":"play_count"}}"#
        }
        #expect(json == expected)
    }

    @Test("created under its own id, once, and not again after deletion")
    func creation() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        let id = BuiltInPlaylist.rediscover.id(forUser: "1")
        let built = BuiltInPlaylist.rediscover
        #expect(try store.playlistRowExists(id) == false)
        let created = try store.createPlaylist(name: built.name, notes: built.notes, id: id)
        #expect(created.id == id)
        #expect(try store.playlistRowExists(id))
        try store.deletePlaylist(id)
        #expect(try store.playlist(id) == nil)
        #expect(try store.playlistRowExists(id), "a deleted built-in must not be recreated")
    }
}
