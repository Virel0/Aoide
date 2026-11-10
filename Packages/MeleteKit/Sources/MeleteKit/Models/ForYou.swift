import Foundation

/// A listener's For You list (`GET /api/v1/music/for-you`): songs suggested from
/// what they finished lately, by ListenBrainz through Melete. Some are in the
/// library to play, the rest can be asked for. Servers before For You answer 404.
public struct ForYou: Equatable, Sendable {
    public enum State: String, Sendable {
        /// For You, or MusicBrainz, is off on the server. Also a state this app
        /// doesn't know, which it shows as nothing.
        case off
        /// Nothing finished in the last 90 days to go on.
        case noHistory = "no_history"
        /// Not made yet: the server makes it in the background.
        case waiting
        /// Made; `items` are its songs, possibly none.
        case ready
    }

    public let state: State
    /// When the list was made; nil until it's ready.
    public let madeAt: Date?
    /// Best first. An item this app can't use (a state it doesn't know, or a song
    /// to play without its track) is left out.
    public let items: [ForYouItem]
}

/// One song of a For You list.
public struct ForYouItem: Equatable, Identifiable, Sendable {
    public enum Offer: Equatable, Sendable {
        /// In the library.
        case playable(MusicItem)
        /// Not in the library, and wanted already or asked for by this listener
        /// (`requestId`, their request, when they asked).
        case requested(ForYouSong, requestId: Int64?)
        /// Not in the library, to ask for.
        case requestable(ForYouSong)
    }

    public var offer: Offer
    public let because: ForYouBecause

    public init(offer: Offer, because: ForYouBecause) {
        self.offer = offer
        self.because = because
    }

    public var id: String {
        switch offer {
        case .playable(let track): "track-\(track.id)"
        case .requested(let song, _), .requestable(let song): "song-\(song.mbRecordingId)"
        }
    }

    /// The library's track, for one to play.
    public var track: MusicItem? {
        if case .playable(let track) = offer { return track }
        return nil
    }
}

/// A song For You suggests that the library doesn't have: what
/// `POST /api/v1/requests` takes to ask for it, and what to show.
public struct ForYouSong: Decodable, Equatable, Hashable, Sendable {
    /// Always `.song`.
    public let kind: RequestKind
    public let mbRecordingId: String
    public let title: String
    /// Its artists, as one line.
    public let artist: String
    /// Its credited artists' MusicBrainz ids, in order; empty when not known.
    public let mbArtistIds: [String]
    /// The album it's listed from.
    public let release: String?
    /// Its album's cover's path on the server; nil while the server has covers of
    /// music not in the library off.
    public let poster: String?

    enum CodingKeys: String, CodingKey {
        case kind, mbRecordingId, title, artist, mbArtistIds, release, poster
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(RequestKind.self, forKey: .kind) ?? .song
        mbRecordingId = try container.decode(String.self, forKey: .mbRecordingId)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        mbArtistIds = try container.decodeIfPresent([String].self, forKey: .mbArtistIds) ?? []
        release = try container.decodeIfPresent(String.self, forKey: .release)
        poster = try container.decodeIfPresent(String.self, forKey: .poster)
    }
}

/// The song or artist of the listener's a suggestion came from.
public struct ForYouBecause: Decodable, Equatable, Hashable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case song, artist

        /// A kind this app doesn't know reads as an artist: its name is always sent.
        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .artist
        }
    }

    public let kind: Kind
    /// The song's title; nil for an artist.
    public let title: String?
    /// The song's artist, or the artist's name.
    public let artist: String

    /// "Because you listened to Low Tide", or to an artist's name.
    public var line: String {
        let title = title?.trimmingCharacters(in: .whitespaces)
        let subject = (kind == .song ? title : nil).flatMap { $0.isEmpty ? nil : $0 } ?? artist
        return "Because you listened to \(subject)"
    }
}

// MARK: - Wire

/// `MusicForYou`, as sent.
struct WireForYou: Decodable {
    struct Item: Decodable {
        let state: String
        let track: WireTrack?
        let song: ForYouSong?
        let requestId: Int64?
        let because: ForYouBecause
    }

    let state: String
    let madeAt: Int64?
    let items: [Item]?

    var forYou: ForYou {
        let state = ForYou.State(rawValue: state) ?? .off
        let items = state == .ready ? (items ?? []).compactMap(Self.item) : []
        return ForYou(state: state, madeAt: madeAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, items: items)
    }

    private static func item(_ wire: Item) -> ForYouItem? {
        let offer: ForYouItem.Offer
        switch (wire.state, wire.track, wire.song) {
        case ("playable", let track?, _): offer = .playable(track.item)
        case ("requested", _, let song?): offer = .requested(song, requestId: wire.requestId)
        case ("requestable", _, let song?): offer = .requestable(song)
        default: return nil
        }
        return ForYouItem(offer: offer, because: wire.because)
    }
}
