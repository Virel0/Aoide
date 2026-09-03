import Foundation

/// Reads a playlist id out of whatever somebody pasted.
///
/// A share sheet gives `https://open.spotify.com/playlist/{id}?si=…`; the desktop
/// app's "copy Spotify URI" gives `spotify:playlist:{id}`; an embed gives the
/// `/embed/playlist/` form. All three name the same thing.
public enum SpotifyLink {
    /// The 22-character base-62 id, or nil when this is not a playlist link.
    public static func playlistId(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?:spotify:playlist:|open\.spotify\.com/(?:embed/)?playlist/)([A-Za-z0-9]{22})"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression) else { return nil }
        let found = String(trimmed[match])
        return String(found.suffix(22))
    }

    /// The page that carries the track list without an account or a key.
    public static func embedURL(playlistId: String) -> URL {
        URL(string: "https://open.spotify.com/embed/playlist/\(playlistId)")!
    }

    /// The embed page never lists more than this many tracks, whatever the playlist holds.
    public static let embedTrackLimit = 100
}
