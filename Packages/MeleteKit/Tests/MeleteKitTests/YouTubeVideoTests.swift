import Testing
@testable import MeleteKit

@Suite("YouTube video as a song")
struct YouTubeVideoTests {
    @Test("title and channel to song and artists", arguments: [
        ("LISA - Tarantino (Official Music Video)", "LISAOfficialVEVO", "Tarantino", ["LISA"]),
        ("Shakira, Burna Boy - Dai Dai (Official Video)", "shakiraVEVO", "Dai Dai", ["Shakira", "Burna Boy"]),
        ("ATEEZ(에이티즈) - 'Drip' Official MV", "KQ ENTERTAINMENT", "Drip", ["ATEEZ"]),
        ("Alfaaz | Hamza Malik x Zain Zohaib | Official Visualiser", "Hamza Malik", "Alfaaz", ["Hamza Malik"]),
        ("Dj Goja x Jason Derulo - Mi Chico (Official Music Video)", "x", "Mi Chico", ["Dj Goja", "Jason Derulo"]),
        ("Creep - Remastered", "Radiohead - Topic", "Creep - Remastered", ["Radiohead"]),
        ("Crazy in Love (feat. Jay-Z)", "Beyoncé - Topic", "Crazy in Love (feat. Jay-Z)", ["Beyoncé"]),
        ("Music", "Madonna", "Music", ["Madonna"]),
        ("Official Video", "Someone", "Official Video", ["Someone"]),
        ("Untitled", "", "Untitled", []),
        ("Barsaat - Banjaare (Official Video)", "Banjaare", "Barsaat", ["Banjaare"]),
        ("Ala Bolelo - Lyric Video | Jailer 2 | Anirudh", "Sun TV", "Ala Bolelo", ["Sun TV"]),
        ("KATSEYE (캣츠아이) 'Hootie Frutti' Official MV", "HYBE LABELS", "Hootie Frutti", ["KATSEYE"]),
        ("ILLIT (아일릿) '체포하겠어 (You’re Under Arrest)’ Official MV", "HYBE LABELS", "체포하겠어 (You’re Under Arrest)", ["ILLIT"]),
        ("Felipe & Rodrigo -  Pós (Ao Vivo) #NoSentimento", "Felipe e Rodrigo", "Pós (Ao Vivo)", ["Felipe & Rodrigo"]),
        ("#1 Crush", "Garbage", "#1 Crush", ["Garbage"]),
        ("Don't Stop Believin'", "JourneyVEVO", "Don't Stop Believin'", ["Journey"]),
    ] as [(String, String, String, [String])])
    func song(_ title: String, _ channel: String, _ song: String, _ artists: [String]) {
        let found = YouTubeVideo.song(title: title, channel: channel)
        #expect(found.title == song)
        #expect(found.artists == artists)
        #expect(found.isMusicTrack == channel.hasSuffix(" - Topic"))
    }
}
