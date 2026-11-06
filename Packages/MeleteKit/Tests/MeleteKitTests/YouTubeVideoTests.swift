import Testing
@testable import MeleteKit

@Suite("YouTube video as a song")
struct YouTubeVideoTests {
    @Test("title and channel to song and artists", arguments: [
        Case("LISA - Tarantino (Official Music Video)", "LISAOfficialVEVO", "Tarantino", ["LISA"]),
        Case("Shakira, Burna Boy - Dai Dai (Official Video)", "shakiraVEVO", "Dai Dai", ["Shakira", "Burna Boy"]),
        Case("ATEEZ(에이티즈) - 'Drip' Official MV", "KQ ENTERTAINMENT", "Drip", ["ATEEZ"]),
        Case("Alfaaz | Hamza Malik x Zain Zohaib | Official Visualiser", "Hamza Malik", "Alfaaz", ["Hamza Malik"]),
        Case("Dj Goja x Jason Derulo - Mi Chico (Official Music Video)", "x", "Mi Chico", ["Dj Goja", "Jason Derulo"]),
        Case("Creep - Remastered", "Radiohead - Topic", "Creep - Remastered", ["Radiohead"]),
        Case("Crazy in Love (feat. Jay-Z)", "Beyoncé - Topic", "Crazy in Love (feat. Jay-Z)", ["Beyoncé"]),
        Case("Music", "Madonna", "Music", ["Madonna"]),
        Case("Official Video", "Someone", "Official Video", ["Someone"]),
        Case("Untitled", "", "Untitled", []),
        Case("Barsaat - Banjaare (Official Video)", "Banjaare", "Barsaat", ["Banjaare"]),
        Case("Ala Bolelo - Lyric Video | Jailer 2 | Anirudh", "Sun TV", "Ala Bolelo", ["Sun TV"]),
        Case("KATSEYE (캣츠아이) 'Hootie Frutti' Official MV", "HYBE LABELS", "Hootie Frutti", ["KATSEYE"]),
        Case("ILLIT (아일릿) '체포하겠어 (You’re Under Arrest)’ Official MV", "HYBE LABELS", "체포하겠어 (You’re Under Arrest)", ["ILLIT"]),
        Case("Felipe & Rodrigo -  Pós (Ao Vivo) #NoSentimento", "Felipe e Rodrigo", "Pós (Ao Vivo)", ["Felipe & Rodrigo"]),
        Case("#1 Crush", "Garbage", "#1 Crush", ["Garbage"]),
        Case("Don't Stop Believin'", "JourneyVEVO", "Don't Stop Believin'", ["Journey"]),
    ])
    func song(_ given: Case) {
        #expect(YouTubeVideo.song(title: given.title, channel: given.channel) == YouTubeVideo.Song(
            title: given.song, artists: given.artists, isMusicTrack: given.channel.hasSuffix(" - Topic")
        ))
    }

    /// A video's title and channel, and the song and artists it should be read as.
    struct Case: Sendable, CustomTestStringConvertible {
        let title: String
        let channel: String
        let song: String
        let artists: [String]

        init(_ title: String, _ channel: String, _ song: String, _ artists: [String]) {
            (self.title, self.channel, self.song, self.artists) = (title, channel, song, artists)
        }

        var testDescription: String { "\(title) on \(channel)" }
    }
}
