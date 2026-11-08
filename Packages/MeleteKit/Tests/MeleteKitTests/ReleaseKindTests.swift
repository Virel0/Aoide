import Foundation
import Testing
@testable import MeleteKit

@Suite("An album's kind of release")
struct ReleaseKindTests {
    private func kind(
        _ primary: String?, _ secondary: [String] = [], compilation: Bool = false, tracks: Int? = 10
    ) -> ReleaseKind {
        .of(primaryType: primary, secondaryTypes: secondary, compilation: compilation, tracks: tracks)
    }

    @Test("each type goes under its own heading")
    func types() {
        #expect(kind("Album") == .albums)
        #expect(kind("Single") == .singles)
        #expect(kind("EP") == .singles)
        #expect(kind("Album", ["Live"]) == .live)
        #expect(kind("Album", ["Compilation"]) == .compilations)
        #expect(kind("Broadcast") == .albums)
    }

    @Test("Live comes before Compilation, and both before Single or EP")
    func precedence() {
        #expect(kind("Album", ["Compilation", "Live"]) == .live)
        #expect(kind("Single", ["Live"]) == .live)
        #expect(kind("EP", ["Compilation"]) == .compilations)
        #expect(kind("Single", compilation: true) == .compilations)
    }

    @Test("a known type wins over the length")
    func typeOverLength() {
        #expect(kind("Album", tracks: 2) == .albums)
        #expect(kind("Single", tracks: 12) == .singles)
    }

    @Test("with no type, 3 tracks or fewer is a single or EP, as before Melete gave types")
    func noType() {
        #expect(kind(nil, tracks: 3) == .singles)
        #expect(kind(nil, tracks: 4) == .albums)
        #expect(kind(nil, tracks: nil) == .albums)
        #expect(kind(nil, compilation: true, tracks: 2) == .compilations)
    }

    @Test("an album's answer carries its kind; an older server's gives the length's")
    func decoded() throws {
        var raw = Fixture.album(2, "Live at Home")
        raw["primary_type"] = "Album"
        raw["secondary_types"] = ["Live"]
        raw["compilation"] = false
        let live = try JSONDecoder.melete.decode(WireAlbum.self, from: Fixture.json(raw)).item
        #expect(live.releaseKind == .live)
        // `Fixture.album` has 2 tracks and none of the new fields.
        let old = try JSONDecoder.melete.decode(WireAlbum.self, from: Fixture.json(Fixture.album(3, "Old")))
        #expect(old.item.releaseKind == .singles)
    }

    @Test("grouping keeps the headings' order and leaves out empty ones")
    func grouping() {
        func album(_ id: String, _ kind: ReleaseKind?) -> MusicItem {
            MusicItem(id: id, name: id, type: .musicAlbum, releaseKind: kind)
        }
        let groups = ReleaseKind.grouped([
            album("c", .compilations), album("s", .singles), album("a", .albums), album("x", nil),
        ])
        #expect(groups.map(\.kind) == [.albums, .singles, .compilations])
        #expect(groups[0].albums.map(\.id) == ["a", "x"])
    }
}
