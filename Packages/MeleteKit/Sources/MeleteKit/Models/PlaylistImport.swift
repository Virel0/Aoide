import Foundation

/// A playlist asked for song by song, as the list shows it.
public struct PlaylistImportSummary: Decodable, Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    /// `queued`, `running`, `done` or `failed`.
    public let state: String
    /// How it went, once done or failed.
    public let message: String?
    /// Unix seconds.
    public let createdAt: Int64
    /// Songs in the playlist.
    public let tracks: Int
    /// Songs this import asked for.
    public let asked: Int
    /// Songs asked for already.
    public let already: Int
    /// Songs no MusicBrainz recording fitted.
    public let unmatched: Int
    /// Of those asked for, the ones still waiting for an admin.
    public let waiting: Int
    /// Songs the library has already, put in the import's playlist as they are.
    /// `nil` from a server before playlists were made by imports.
    public let inLibrary: Int?
    /// The Aoide playlist the import makes and fills, when it makes one.
    public let playlistId: String?

    /// Songs worked through so far.
    public var handled: Int { asked + already + unmatched + (inLibrary ?? 0) }

    /// Still working through its songs.
    public var isRunning: Bool { state == "queued" || state == "running" }

    /// "Done: 12 of 20 songs asked for, 3 asked already, 5 not found. 4 wait for approval."
    public var tally: String {
        let word = switch state {
        case "queued": "Waiting to start"
        case "running": "Asking"
        case "failed": "Stopped"
        default: "Done"
        }
        var words = "\(word): \(asked) of \(tracks) songs asked for, \(already) asked already, \(unmatched) not found."
        if let inLibrary, inLibrary > 0 { words += " \(inLibrary) in your library already." }
        if waiting > 0 { words += " \(waiting) wait for approval." }
        if let message { words += " \(message)" }
        return words
    }
}

/// One song of a playlist import.
public struct PlaylistImportTrack: Decodable, Equatable, Identifiable, Sendable {
    /// Its place in the playlist, from 1.
    public let position: Int
    public let title: String
    /// As the playlist names them.
    public let artist: String?
    /// `pending`, `asked`, `already`, `unmatched` or `in_library`.
    public let state: String
    /// Why it wasn't asked for, when unmatched.
    public let why: String?
    /// The request it became, or the one asked already.
    public let requestId: Int64?

    public var id: Int { position }

    /// What became of it, in words.
    public var standing: String {
        switch state {
        case "asked": "Asked for"
        case "already": "Asked for already"
        case "unmatched": why.map { "Not found: \($0)" } ?? "Not found"
        case "in_library": "In your library"
        default: "Not looked up yet"
        }
    }
}

/// A playlist import, song by song.
public struct PlaylistImport: Decodable, Equatable, Sendable {
    public let summary: PlaylistImportSummary
    public let items: [PlaylistImportTrack]

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: any Decoder) throws {
        summary = try PlaylistImportSummary(from: decoder)
        items = try decoder.container(keyedBy: CodingKeys.self).decode([PlaylistImportTrack].self, forKey: .items)
    }
}

/// A playlist as the CSV Melete reads, in Exportify's columns: a header, then a
/// row a song (title, artists, album, length in milliseconds, ISRC).
public enum PlaylistCSV {
    public static func make(_ tracks: [ImportedTrack]) -> String {
        func quoted(_ field: String) -> String { "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        var csv = "Track Name,Artist Name(s),Album Name,Track Duration (ms),ISRC\n"
        for track in tracks {
            let row = [
                quoted(track.title),
                quoted(track.artists.joined(separator: ", ")),
                quoted(track.album ?? ""),
                track.durationMs.map(String.init) ?? "",
                quoted(track.isrc ?? ""),
            ]
            csv += row.joined(separator: ",") + "\n"
        }
        return csv
    }
}
