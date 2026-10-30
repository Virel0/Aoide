import Foundation

/// Pulls the track list out of Spotify's embed page.
///
/// The public playlist page renders on the client and carries no data; the embed
/// page ships its state in a `__NEXT_DATA__` script for the player to hydrate
/// from. Undocumented, so this is written to fail loudly — a shape change should
/// read as "Spotify changed its page", never as an empty playlist.
public enum SpotifyEmbedParser {
    public enum Failure: Error, Equatable {
        case noEmbeddedState
        case unexpectedShape(String)
    }

    public static func parse(html: String) throws -> ImportedPlaylist {
        guard let json = embeddedJSON(in: html) else { throw Failure.noEmbeddedState }
        return try parse(stateJSON: json)
    }

    /// The JSON between the state script's tags, or nil if the page has none.
    static func embeddedJSON(in html: String) -> Data? {
        let open = #"<script id="__NEXT_DATA__" type="application/json">"#
        guard let start = html.range(of: open) else { return nil }
        guard let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else { return nil }
        return Data(html[start.upperBound..<end.lowerBound].utf8)
    }

    static func parse(stateJSON data: Data) throws -> ImportedPlaylist {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.unexpectedShape("state is not JSON")
        }

        guard let entity = dig(root, "props", "pageProps", "state", "data", "entity") as? [String: Any] else {
            throw Failure.unexpectedShape("no entity at props.pageProps.state.data.entity")
        }
        guard let list = entity["trackList"] as? [[String: Any]] else {
            throw Failure.unexpectedShape("entity has no trackList")
        }

        let tracks = list.compactMap { row -> ImportedTrack? in
            guard let title = row["title"] as? String, !title.isEmpty else { return nil }
            let subtitle = (row["subtitle"] as? String) ?? ""
            // Artists arrive as one comma-joined string. A name with a comma in it
            // splits wrong, and there is nothing in the page to tell those apart.
            let artists = subtitle
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let duration = (row["duration"] as? NSNumber)?.intValue
            return ImportedTrack(title: title, artists: artists, album: nil, durationMs: duration, isrc: nil)
        }

        let name = (entity["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Spotify playlist"
        return ImportedPlaylist(
            name: name,
            tracks: tracks,
            isTruncated: list.count >= SpotifyLink.embedTrackLimit
        )
    }

    private static func dig(_ value: Any, _ keys: String...) -> Any? {
        var current: Any? = value
        for key in keys {
            guard let object = current as? [String: Any] else { return nil }
            current = object[key]
        }
        return current
    }
}
