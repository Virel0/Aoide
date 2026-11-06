import Foundation

/// A playlist as another service describes it: names and lengths, no ids we can use.
///
/// Whether it came from a Spotify link or a CSV export, this is all there is to go
/// on — which is why matching against the library is a separate, careful step
/// rather than a lookup.
public struct ImportedPlaylist: Equatable, Sendable {
    public var name: String
    public var tracks: [ImportedTrack]
    /// True when the source is known to hold more than it handed over — the
    /// Spotify embed page stops at a hundred tracks and says nothing about it.
    public var isTruncated: Bool

    public init(name: String, tracks: [ImportedTrack], isTruncated: Bool = false) {
        self.name = name
        self.tracks = tracks
        self.isTruncated = isTruncated
    }
}

public struct ImportedTrack: Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(title)|\(artists.joined(separator: ","))|\(durationMs ?? 0)" }
    public var title: String
    /// Every credited artist, first the main one.
    public var artists: [String]
    public var album: String?
    public var durationMs: Int?
    /// Present only in CSV exports. Kept because it is the one exact key that
    /// exists, should the library ever carry it too.
    public var isrc: String?
    /// The artist is only a guess: a YouTube video's channel, which may be a
    /// label ("Ubisoft Music"). Such a track the library has under another artist
    /// is found by its title alone (`TrackMatcher.byTitleAlone`). Never sent.
    public var artistFromChannel: Bool

    public init(
        title: String, artists: [String], album: String? = nil, durationMs: Int? = nil,
        isrc: String? = nil, artistFromChannel: Bool = false
    ) {
        self.title = title
        self.artists = artists
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
        self.artistFromChannel = artistFromChannel
    }
}
