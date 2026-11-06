import Foundation

/// A YouTube video read as a song: an export of a YouTube playlist has the video's
/// title and channel, not a song title and artist.
///
/// - A YouTube Music track's channel is "Artist - Topic", and its title is the song.
/// - A music video's title is usually "Artist - Song (Official Video)", or
///   "Song - Artist" on the artist's own channel.
/// - A K-pop video's is often "Artist 'Song' Official MV".
/// - Otherwise the channel stands for the artist, less "VEVO" and "Official".
///
/// Only a YouTube Music track's length is the song's: a video's runs over with
/// its intro and ending, and would rule out the very recording it shows.
///
/// What video sites add to a title (Official Video, Lyric Video, M/V, hashtags, a
/// " | " and what follows) is taken off first, so Melete looks the song up by its
/// own name. Aoide for Linux's `import/youtube.rs` follows the same rules.
public enum YouTubeVideo {
    /// The song title and artists a video's `title` and `channel` stand for, and
    /// whether it's a YouTube Music track, whose length is the song's.
    public static func song(
        title: String, channel: String
    ) -> (title: String, artists: [String], isMusicTrack: Bool) {
        if let artist = topicArtist(channel) {
            return (songTitle(title), [artist], true)
        }
        let (song, artists) = videoSong(title: title, channel: channel)
        return (song, artists, false)
    }

    private static func videoSong(title: String, channel: String) -> (String, [String]) {
        let named = channelArtist(channel)
        let cleaned = songTitle(title)
        if let (left, right) = artistDash(cleaned) {
            let song = songTitle(right)
            if !named.isEmpty, plain(song) == plain(named), plain(left) != plain(named) {
                return (songTitle(left), [named])
            }
            return (song, artists(withoutGroups(left)))
        }
        if let (left, song) = quotedSong(cleaned) {
            return (song, artists(withoutGroups(left)))
        }
        return (cleaned, named.isEmpty ? [] : [named])
    }

    /// The artist of a YouTube Music "Artist - Topic" channel.
    private static func topicArtist(_ channel: String) -> String? {
        let suffix = " - Topic"
        guard channel.lowercased().hasSuffix(suffix.lowercased()) else { return nil }
        let artist = String(channel.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        return artist.isEmpty ? nil : artist
    }

    /// "Artist - Song" split at its first dash, both sides there.
    private static func artistDash(_ title: String) -> (String, String)? {
        for dash in [" - ", " – ", " — "] {
            guard let range = title.range(of: dash) else { continue }
            let left = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !left.isEmpty, !right.isEmpty { return (left, right) }
        }
        return nil
    }

    /// "Artist 'Song'": a quoted song at the end, after a space.
    private static func quotedSong(_ title: String) -> (String, String)? {
        let openers: Set<Character> = ["'", "‘", "\"", "“"]
        let closers: Set<Character> = ["'", "’", "\"", "”"]
        guard let last = title.last, closers.contains(last) else { return nil }
        let body = title.dropLast()
        var at = body.endIndex
        while at > body.startIndex {
            at = body.index(before: at)
            guard openers.contains(body[at]), at > body.startIndex,
                  body[body.index(before: at)] == " " else { continue }
            let left = body[..<at].trimmingCharacters(in: .whitespaces)
            let song = body[body.index(after: at)...].trimmingCharacters(in: .whitespaces)
            return left.isEmpty || song.isEmpty ? nil : (left, song)
        }
        return nil
    }

    /// The channel's name without "VEVO" or "Official" stuck to its end.
    private static func channelArtist(_ channel: String) -> String {
        var name = channel.trimmingCharacters(in: .whitespaces)
        for suffix in ["VEVO", "Vevo", "Official"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return name
    }

    /// Several artists as a video names them: "A, B", "A x B", "A feat. B".
    private static func artists(_ text: String) -> [String] {
        var parts = [text]
        for separator in [",", " x ", " X ", " feat. ", " ft. ", " Feat. ", " Ft. "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Bracketed parts taken out: "ILLIT (아일릿)" is ILLIT.
    private static func withoutGroups(_ text: String) -> String {
        var result = text
        for (open, close) in brackets {
            result = removingGroups(result, open: open, close: close) { _ in true }
        }
        let kept = tidy(result)
        return kept.isEmpty ? text : kept
    }

    /// Letters and digits only, lower-cased: for telling two names apart.
    private static func plain(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func tidy(_ text: String) -> String {
        text.split(separator: " ").joined(separator: " ")
    }

    // MARK: - The title

    private static let brackets: [(Character, Character)] = [("(", ")"), ("[", "]"), ("【", "】"), ("「", "」")]

    /// Words that mark a bracketed part as the video's, not the song's.
    private static let videoWords: Set<String> = [
        "official", "oficial", "video", "videoclip", "audio", "lyric", "lyrics", "lyrical",
        "visualizer", "visualiser", "visual", "mv", "hd", "4k", "hq",
    ]

    /// What a title may end with that names the video, longest first.
    private static let videoEndings = [
        "official music video", "official lyric video", "official visualizer", "official visualiser",
        "official video", "official audio", "official mv", "official m/v", "music video",
        "lyric video", "video oficial", "m/v", "mv",
    ]

    /// The song's title out of a video's: no " | " and what follows, no hashtags,
    /// no bracketed video words, no "Official Video" at the end, no quotes around it.
    static func songTitle(_ title: String) -> String {
        let first = title.components(separatedBy: " | ").first ?? title
        // "#NoSentimento" goes; "#1 Crush" stays.
        var song = first.split(separator: " ")
            .filter { !($0.hasPrefix("#") && $0.dropFirst().first?.isLetter == true) }
            .joined(separator: " ")
        for (open, close) in brackets {
            song = removingGroups(song, open: open, close: close, drop: isVideoPart)
        }
        song = withoutVideoEnding(song)
        song = song.trimmingCharacters(in: CharacterSet(charactersIn: " -,:"))
        let kept = tidy(unquoted(song))
        return kept.isEmpty ? title.trimmingCharacters(in: .whitespaces) : kept
    }

    /// `text` without the bracketed parts whose inside (lower-cased) `drop` says to drop.
    private static func removingGroups(
        _ text: String, open: Character, close: Character, drop: (String) -> Bool
    ) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: open), let end = rest[start...].firstIndex(of: close) {
            result += rest[..<start]
            if !drop(rest[rest.index(after: start)..<end].lowercased()) {
                result += rest[start...end]
            }
            rest = rest[rest.index(after: end)...]
        }
        return result + rest
    }

    /// Whether a bracketed part names the video: (Official Video), [M/V], (Lyrics).
    private static func isVideoPart(_ inside: String) -> Bool {
        let words = inside.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return inside.contains("m/v") || words.contains(where: videoWords.contains)
    }

    private static func withoutVideoEnding(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while let ending = videoEndings.first(where: { result.lowercased().hasSuffix(" " + $0) }) {
            result = String(result.dropLast(ending.count)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// 'NEON' or “NEON” is NEON.
    private static func unquoted(_ text: String) -> String {
        let quotes: Set<Character> = ["'", "\"", "‘", "’", "“", "”"]
        guard text.count > 2, let first = text.first, let last = text.last,
              quotes.contains(first), quotes.contains(last)
        else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
}
