import Foundation

/// Reads a playlist out of a CSV export — Exportify's by default, with enough
/// tolerance for the other tools' column names.
///
/// The one route that carries a *whole* playlist plus ISRC and album, which the
/// embed page does not. Exportify's headers are matched exactly first; the
/// aliases exist because every export tool names "the title column" differently
/// and a person should not have to know which one they used.
public enum PlaylistCSVParser {
    public enum Failure: Error, Equatable {
        case empty
        case noTitleColumn
    }

    private static let titleHeaders = ["track name", "title", "track", "name", "song"]
    private static let artistHeaders = ["artist name(s)", "artist name", "artist", "artists", "artist(s)"]
    private static let albumHeaders = ["album name", "album"]
    private static let durationHeaders = ["track duration (ms)", "duration (ms)", "duration_ms", "duration"]
    private static let isrcHeaders = ["isrc"]

    public static func parse(_ text: String, name: String) throws -> ImportedPlaylist {
        let rows = CSV.rows(from: text).filter { !$0.allSatisfy(\.isEmpty) }
        guard let header = rows.first else { throw Failure.empty }

        let columns = header.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func index(of names: [String]) -> Int? {
            for name in names {
                if let found = columns.firstIndex(of: name) { return found }
            }
            return nil
        }

        guard let title = index(of: titleHeaders) else { throw Failure.noTitleColumn }
        let artist = index(of: artistHeaders)
        let album = index(of: albumHeaders)
        let duration = index(of: durationHeaders)
        let isrc = index(of: isrcHeaders)

        let tracks = rows.dropFirst().compactMap { row -> ImportedTrack? in
            func cell(_ column: Int?) -> String? {
                guard let column, column < row.count else { return nil }
                let value = row[column].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let name = cell(title) else { return nil }
            let artists = (cell(artist) ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let ms = cell(duration).flatMap { value -> Int? in
                // Exportify writes milliseconds; a hand-made sheet may write mm:ss.
                if let number = Int(value) { return number }
                let parts = value.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { return nil }
                return (parts[0] * 60 + parts[1]) * 1000
            }
            return ImportedTrack(title: name, artists: artists, album: cell(album), durationMs: ms, isrc: cell(isrc))
        }

        return ImportedPlaylist(name: name, tracks: tracks)
    }
}

/// Just enough of RFC 4180: quoted fields, doubled quotes, newlines inside quotes.
enum CSV {
    static func rows(from text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        // Scalars, not characters: Swift treats "\r\n" as one character, which
        // matches neither "\r" nor "\n" and turns a Windows export into one row.
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let held = pending { pending = nil; return held }
            return iterator.next()
        }

        while let character = next() {
            if quoted {
                if character == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { quoted = false; pending = following }
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case ",":
                row.append(field); field = ""
            case "\r":
                break
            case "\n":
                row.append(field); rows.append(row); row = []; field = ""
            default:
                field.unicodeScalars.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field); rows.append(row)
        }
        return rows
    }
}
