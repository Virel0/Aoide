import Foundation
import Testing
@testable import JellyfinKit

/// One table of cases, mirrored line for line by the desktop app's
/// `track-matcher.test.ts`. Change a row here and change it there, or the two
/// apps will disagree about what is missing from the same playlist.
@Suite("Track matching")
struct TrackMatcherTests {
    struct Row: Sendable {
        let title: String, artists: [String], ms: Int?
        let candidateTitle: String, candidateArtists: [String], candidateMs: Int?
        let accepted: Bool
        let why: String
    }

    static let table: [Row] = [
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead"], candidateMs: 264_066,
            accepted: true, why: "plain equal"),
        Row(title: "Karma Police - Remastered 2009", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead"], candidateMs: 264_000,
            accepted: true, why: "dash suffix with a noise word is dropped"),
        Row(title: "Crazy in Love (feat. Jay-Z)", artists: ["Beyoncé", "JAY-Z"], ms: 236_000,
            candidateTitle: "Crazy In Love", candidateArtists: ["Beyonce"], candidateMs: 235_000,
            accepted: true, why: "feat group dropped, diacritics folded, any artist pair"),
        Row(title: "(What's the Story) Morning Glory?", artists: ["Oasis"], ms: 300_000,
            candidateTitle: "(What's The Story) Morning Glory?", candidateArtists: ["Oasis"], candidateMs: 300_000,
            accepted: true, why: "a bracket group without a noise word is kept"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead"], candidateMs: 290_000,
            accepted: false, why: "26 seconds off is a different recording"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead"], candidateMs: 276_000,
            accepted: true, why: "12 seconds off is a different edit, still accepted"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: nil,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead"], candidateMs: 264_000,
            accepted: true, why: "unknown duration on one side is not held against it"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Radiohead Tribute Band"], candidateMs: 264_000,
            accepted: true, why: "artist words all inside the other's still count"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: ["Coldplay"], candidateMs: 264_000,
            accepted: false, why: "same title, different artist"),
        Row(title: "Karma Police", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: [], candidateMs: 264_000,
            accepted: true, why: "untagged artist, exact title: trusted"),
        Row(title: "Karma Police (Live)", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: [], candidateMs: 264_000,
            accepted: true, why: "untagged artist, title exact after noise removal"),
        Row(title: "Karma Polic", artists: ["Radiohead"], ms: 264_000,
            candidateTitle: "Karma Police", candidateArtists: [], candidateMs: 264_000,
            accepted: false, why: "untagged artist, inexact title: not trusted"),
        Row(title: "Rock & Roll", artists: ["Led Zeppelin"], ms: 220_000,
            candidateTitle: "Rock and Roll", candidateArtists: ["Led Zeppelin"], candidateMs: 220_000,
            accepted: true, why: "ampersand is 'and'"),
        Row(title: "Song 2", artists: ["Blur"], ms: 122_000,
            candidateTitle: "Song 3", candidateArtists: ["Blur"], candidateMs: 122_000,
            accepted: false, why: "one of two words differs: 1/3 overlap"),
        Row(title: "The Less I Know the Better", artists: ["Tame Impala"], ms: 216_000,
            candidateTitle: "The Less I Know The Better - Single Version", candidateArtists: ["Tame Impala"], candidateMs: 216_000,
            accepted: true, why: "library side carries the noise suffix"),
    ]

    @Test("the table", arguments: table.indices)
    func row(_ index: Int) {
        let row = Self.table[index]
        let track = ImportedTrack(title: row.title, artists: row.artists, durationMs: row.ms)
        let candidate = TrackMatcher.Candidate(title: row.candidateTitle, artists: row.candidateArtists, durationMs: row.candidateMs)
        let verdict = TrackMatcher.verdict(for: track, against: candidate)
        #expect(verdict.isAccepted == row.accepted, "\(row.why): \(verdict)")
    }

    @Test("normalisation, as specified", arguments: [
        ("Crazy in Love (feat. Jay-Z)", "crazy in love"),
        ("Karma Police - Remastered 2009", "karma police"),
        ("(What's the Story) Morning Glory?", "what s the story morning glory"),
        ("Beyoncé & JAY-Z", "beyonce and jay z"),
        ("Song [Live at Wembley]", "song"),
        ("Don't Stop Me Now - 2011 Mix", "don t stop me now"),
        ("Ain't No Mountain High Enough", "ain t no mountain high enough"),
        ("  Spaced   Out  ", "spaced out"),
    ])
    func normalize(_ input: String, _ expected: String) {
        #expect(TrackMatcher.normalize(input) == expected)
    }

    @Test("search terms start with the title as spelled and widen from there", arguments: [
        ("Don't Stop Me Now - 2011 Mix", ["Don't Stop Me Now - 2011 Mix", "Don't Stop Me Now", "don t stop me now", "stop"]),
        ("Karma Police", ["Karma Police", "karma police", "police"]),
        ("Crazy in Love (feat. Jay-Z)", ["Crazy in Love (feat. Jay-Z)", "Crazy in Love", "crazy in love", "crazy"]),
        ("Hey", ["Hey", "hey"]),
    ])
    func searchTerms(_ title: String, _ expected: [String]) {
        #expect(TrackMatcher.searchTerms(for: title) == expected)
    }

    @Test("best picks the highest-scoring accepted candidate, not the first")
    func best() {
        let track = ImportedTrack(title: "Karma Police", artists: ["Radiohead"], durationMs: 264_000)
        let candidates = [
            TrackMatcher.Candidate(title: "Karma Police", artists: ["Radiohead"], durationMs: 276_000),
            TrackMatcher.Candidate(title: "Karma Police", artists: ["Radiohead"], durationMs: 264_000),
            TrackMatcher.Candidate(title: "Karma Police", artists: ["Coldplay"], durationMs: 264_000),
        ]
        #expect(TrackMatcher.best(for: track, among: candidates) == 1)
        #expect(TrackMatcher.best(for: track, among: [candidates[2]]) == nil)
    }
}

@Suite("Spotify links and embed page")
struct SpotifyImportTests {
    @Test("reads the id out of every link shape", arguments: [
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc",
        "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "  https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M  ",
    ])
    func links(_ text: String) {
        #expect(SpotifyLink.playlistId(from: text) == "37i9dQZF1DXcBWIGoYBM5M")
    }

    @Test("refuses things that are not playlist links", arguments: [
        "https://open.spotify.com/track/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/playlist/short",
        "hello",
    ])
    func notLinks(_ text: String) {
        #expect(SpotifyLink.playlistId(from: text) == nil)
    }

    static let page = """
    <html><head><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"type":"playlist","name":"ignored","title":"Road Trip","subtitle":"Alex","trackList":[{"uri":"spotify:track:1","title":"Karma Police","subtitle":"Radiohead","duration":264066,"isExplicit":false},{"uri":"spotify:track:2","title":"Crazy in Love (feat. Jay-Z)","subtitle":"Beyoncé, JAY-Z","duration":236000},{"uri":"spotify:track:3","title":"","subtitle":"Nobody","duration":1}]}}}}}}</script></head><body></body></html>
    """

    @Test("parses the embedded state")
    func parse() throws {
        let playlist = try SpotifyEmbedParser.parse(html: Self.page)
        #expect(playlist.name == "Road Trip")
        #expect(playlist.tracks.count == 2)
        #expect(playlist.tracks[0] == ImportedTrack(title: "Karma Police", artists: ["Radiohead"], durationMs: 264_066))
        #expect(playlist.tracks[1].artists == ["Beyoncé", "JAY-Z"])
        #expect(playlist.isTruncated == false)
    }

    @Test("a hundred tracks means there may be more")
    func truncated() throws {
        let rows = (0..<100).map { #"{"title":"T\#($0)","subtitle":"A","duration":1000}"# }.joined(separator: ",")
        let html = #"<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{"title":"Big","trackList":[\#(rows)]}}}}}}</script>"#
        #expect(try SpotifyEmbedParser.parse(html: html).isTruncated)
    }

    @Test("says so when the page has changed shape rather than returning nothing")
    func shape() {
        #expect(throws: SpotifyEmbedParser.Failure.noEmbeddedState) {
            try SpotifyEmbedParser.parse(html: "<html><body>nothing</body></html>")
        }
        #expect(throws: SpotifyEmbedParser.Failure.unexpectedShape("no entity at props.pageProps.state.data.entity")) {
            try SpotifyEmbedParser.parse(html: #"<script id="__NEXT_DATA__" type="application/json">{"props":{}}</script>"#)
        }
    }
}

@Suite("Playlist CSV")
struct PlaylistCSVTests {
    @Test("reads an Exportify file, quotes and all")
    func exportify() throws {
        // Raw, because a doubled CSV quote followed by a closing quote is three
        // quotes in a row, which an ordinary literal reads as its own end.
        let csv = #"""
        Track URI,Track Name,Artist URI(s),Artist Name(s),Album URI,Album Name,Track Duration (ms),ISRC
        spotify:track:1,"Crazy in Love (feat. Jay-Z)",x,"Beyoncé, JAY-Z",y,Dangerously in Love,236000,USSM10301234
        spotify:track:2,"Say ""Hi""",x,Someone,y,"Album, with comma",1000,
        """#
        let playlist = try PlaylistCSVParser.parse(csv, name: "From file")
        #expect(playlist.name == "From file")
        #expect(playlist.tracks.count == 2)
        #expect(playlist.tracks[0] == ImportedTrack(
            title: "Crazy in Love (feat. Jay-Z)", artists: ["Beyoncé", "JAY-Z"],
            album: "Dangerously in Love", durationMs: 236_000, isrc: "USSM10301234"
        ))
        #expect(playlist.tracks[1].title == #"Say "Hi""#)
        #expect(playlist.tracks[1].album == "Album, with comma")
        #expect(playlist.tracks[1].isrc == nil)
    }

    @Test("tolerates other tools' headers and mm:ss lengths")
    func aliases() throws {
        let csv = "Title,Artist,Album,Duration\r\nKarma Police,Radiohead,OK Computer,4:24\r\n"
        let playlist = try PlaylistCSVParser.parse(csv, name: "x")
        #expect(playlist.tracks == [ImportedTrack(title: "Karma Police", artists: ["Radiohead"], album: "OK Computer", durationMs: 264_000)])
    }

    @Test("a byte-order mark does not hide the first header")
    func bom() throws {
        let playlist = try PlaylistCSVParser.parse("\u{FEFF}Title,Artist\nKarma Police,Radiohead\n", name: "x")
        #expect(playlist.tracks.map(\.title) == ["Karma Police"])
    }

    @Test("refuses a file with no title column")
    func noTitle() {
        #expect(throws: PlaylistCSVParser.Failure.noTitleColumn) {
            try PlaylistCSVParser.parse("a,b\n1,2\n", name: "x")
        }
    }
}

@Suite("Sidecar match wire form")
struct SidecarMatchTests {
    @Test("sends the imported track exactly as the sidecar reads it")
    func body() throws {
        let track = ImportedTrack(title: "Karma Police", artists: ["Radiohead"], album: nil, durationMs: 264_000, isrc: nil)
        let data = try JellyfinClient.matchBody([track])
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rows.count == 1)
        #expect(rows[0]["title"] as? String == "Karma Police")
        #expect(rows[0]["artists"] as? [String] == ["Radiohead"])
        #expect(rows[0]["durationMs"] as? Int == 264_000)
        // Absent, not null-as-string: the sidecar's fields are optional.
        #expect(rows[0]["album"] == nil || rows[0]["album"] is NSNull)
    }

    @Test("reads a response with a null where the library had nothing")
    func response() throws {
        let json = #"{"results":[{"jellyfinId":"j1","confidence":0.97,"titleScore":1,"artistScore":1,"durationScore":0.8,"title":"Karma Police","artists":["Radiohead"],"album":"OK Computer","durationMs":270000},null],"matched":1,"librarySize":1234}"#
        let response = try JSONDecoder().decode(SidecarMatchResponse.self, from: Data(json.utf8))
        #expect(response.results.count == 2)
        #expect(response.results[0]?.jellyfinId == "j1")
        #expect(response.results[1] == nil)
        #expect(response.matched == 1)
    }
}
