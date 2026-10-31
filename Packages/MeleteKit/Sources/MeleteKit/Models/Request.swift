import Foundation

/// What can be asked for in music.
public enum RequestKind: String, Codable, Sendable, CaseIterable {
    case artist, album, song
    /// Movies and series: never shown here, but a request list may hold them.
    case other

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }

    /// The word a row shows.
    public var word: String {
        switch self {
        case .artist: "Artist"
        case .album: "Album"
        case .song: "Song"
        case .other: "Title"
        }
    }
}

/// Something MusicBrainz knows, as a request search finds it.
public struct RequestCandidate: Decodable, Equatable, Hashable, Sendable {
    public let kind: RequestKind
    /// An artist's, and an album's or song's first artist.
    public let mbArtistId: String?
    /// An album's.
    public let mbReleaseGroupId: String?
    /// A song's.
    public let mbRecordingId: String?
    /// The title, or an artist's name.
    public let title: String
    public let year: Int?
    /// An album's or song's artists, as credited.
    public let artist: String?
    /// What tells it from others of the name: an artist's kind and country, an
    /// album's type, the album a song is on and its length.
    public let detail: String?
    /// On disk already, in a library this user may see.
    public let inLibrary: Bool
    /// On the wanted list and looked out for.
    public let wanted: Bool
    /// This user's open request for it, by id.
    public let requested: Int64?

    /// Whether there's anything left to ask: not here, not wanted, not asked for.
    public var isAskable: Bool { !inLibrary && !wanted && requested == nil }

    /// Its kind, artist, year and detail, for the line under its title. A detail
    /// that only says its kind again (an album whose type is Album) is left out.
    public var about: String {
        let telling = detail.flatMap { $0.caseInsensitiveCompare(kind.word) == .orderedSame ? nil : $0 }
        return ([kind.word, artist, year.map(String.init), telling] as [String?]).compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// How an approved request is getting on.
public struct RequestProgress: Decodable, Equatable, Sendable {
    /// wanted, searching, downloading, transferring, importing, in_library or failed.
    public let step: String
    /// How much is downloaded, while downloading.
    public let percent: Double?
    /// The latest word on it, in plain words.
    public let message: String?
}

/// One of this user's requests.
public struct MusicRequest: Decodable, Equatable, Identifiable, Sendable {
    public enum State: String, Decodable, Sendable {
        /// Waiting for an admin.
        case requested
        case approved
        case declined
    }

    public let id: Int64
    public let kind: RequestKind
    public let title: String
    public let year: Int?
    public let artist: String?
    public let state: State
    /// Why it was declined.
    public let reason: String?
    /// Unix seconds.
    public let createdAt: Int64
    /// How it's getting on, once approved; nil before, and for a whole artist.
    public let progress: RequestProgress?

    /// Where it stands, in words.
    public var standing: String {
        switch state {
        case .requested: return "Waiting for approval"
        case .declined: return reason.map { "Declined: \($0)" } ?? "Declined"
        case .approved:
            guard let progress else { return "Approved" }
            switch progress.step {
            case "wanted": return "Approved, waiting to be looked for"
            case "searching": return "Looking for a download"
            case "downloading": return progress.percent.map { "Downloading, \(Int($0.rounded()))%" } ?? "Downloading"
            case "transferring": return "Copying to your server"
            case "importing": return "Adding to your library"
            case "in_library": return "In your library"
            case "failed": return progress.message.map { "Couldn't be fetched: \($0)" } ?? "Couldn't be fetched"
            default: return progress.message ?? progress.step
            }
        }
    }
}
