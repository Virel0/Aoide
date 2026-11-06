import Testing
@testable import MeleteKit

/// A song whose artist is only a YouTube channel's name, found in the library by its
/// title alone: Aoide for Linux's `tests/title_alone.rs`.
@Suite("Found by title alone")
struct TitleAloneTests {
    private static func song(_ title: String, _ artist: String) -> TrackMatcher.Candidate {
        TrackMatcher.Candidate(title: title, artists: [artist], durationMs: 150_000)
    }

    /// "Fish in the Sea" from a label's channel, the artist only a guess.
    private static func fromALabel(_ title: String) -> ImportedTrack {
        ImportedTrack(title: title, artists: ["Ubisoft Music"], artistFromChannel: true)
    }

    @Test("only a guessed artist, and one artist with exactly the title, will do")
    func rule() {
        let one = [
            Self.song("Fish in the Sea", "Assassin's Creed Shanties"),
            Self.song("Fish in the Sea (Live)", "Assassin's Creed Shanties"),
            Self.song("Big Fish in the Sea", "Someone Else"),
        ]
        #expect(TrackMatcher.byTitleAlone(for: Self.fromALabel("Fish in the Sea"), among: one) == 0)
        let named = ImportedTrack(title: "Fish in the Sea", artists: ["Ubisoft Music"])
        #expect(TrackMatcher.byTitleAlone(for: named, among: one) == nil, "an artist the source named stands")
        let two = [Self.song("Fish in the Sea", "Assassin's Creed Shanties"), Self.song("Fish in the Sea", "Another Band")]
        #expect(TrackMatcher.byTitleAlone(for: Self.fromALabel("Fish in the Sea"), among: two) == nil,
                "two artists: which one the video is can't be told")
        #expect(TrackMatcher.byTitleAlone(for: Self.fromALabel("Fish"), among: one) == nil)
    }

    @Test("a song the library has under another artist is found and takes its artist")
    func found() async {
        let library = [Self.song("Fish in the Sea", "Assassin's Creed Shanties")]
        let search: @Sendable (String) async -> [TrackMatcher.Candidate]? = { term in
            library.filter { $0.title.lowercased().contains(term.lowercased()) }
        }
        let found = await TrackMatcher.findByTitleAlone(Self.fromALabel("Fish in the Sea"), search: search) { $0 }
        #expect(found?.track.artists == ["Assassin's Creed Shanties"], "sent to Melete as the library's")
        #expect(found?.track.artistFromChannel == false)
        #expect(found?.item == library[0])

        let named = ImportedTrack(title: "Fish in the Sea", artists: ["Nobody Here"])
        #expect(await TrackMatcher.findByTitleAlone(named, search: search) { $0 } == nil)
    }
}
