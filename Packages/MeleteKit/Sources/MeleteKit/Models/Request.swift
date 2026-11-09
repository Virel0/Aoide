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
    /// Its picture's path on the server: an album's cover, a song's single's or
    /// album's, an artist's portrait. Nil while the server has these off, and
    /// from servers before 0.8.
    public let poster: String?
    /// Who took an artist's portrait and its licence, to be shown with it.
    public let posterCredit: PosterCredit?

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

/// An artist's portrait's author and licence, from Wikimedia Commons, on a
/// request search's result (`poster_credit`) or a library artist
/// (`portrait_credit`). Its licence (CC BY-SA and the like) asks that both are
/// shown with it.
public struct PosterCredit: Codable, Equatable, Hashable, Sendable {
    public let author: String?
    /// The licence's short name, such as "CC BY-SA 4.0".
    public let licence: String?
    public let licenceUrl: String?
    /// The picture's page on Commons.
    public let sourceUrl: String?

    /// "Photo: Jane Doe, CC BY-SA 4.0"; nil when it names neither.
    public var line: String? {
        let parts = [author, licence].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : "Photo: " + parts.joined(separator: ", ")
    }

    /// Where to read more: the picture's page, else the licence's. Web addresses
    /// only.
    public var link: URL? {
        [sourceUrl, licenceUrl].lazy.compactMap { $0.flatMap(URL.init(string:)) }
            .first { $0.scheme == "https" || $0.scheme == "http" }
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
    /// Where it's coming from: `torrent` or `soulseek`.
    public let source: String?
    /// Unix seconds it last changed; nil for a step worked out from the library.
    public let updatedAt: Int64?
    /// While it's copied home: how far that has got.
    public let copied: RequestCopying?
}

/// A download being copied home to the server.
public struct RequestCopying: Decodable, Equatable, Sendable {
    public let bytes: Int64
    public let total: Int64
    /// The copy's speed so far, once it has run a second.
    public let bytesPerSecond: Int64?
    /// At that speed, rounded up.
    public let secondsLeft: Int64?

    /// "120 MB of 3.4 GB, 12 MB/s, about 5 minutes left".
    public var words: String {
        func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        var words = "\(size(bytes)) of \(size(total))"
        if let bytesPerSecond { words += ", \(size(bytesPerSecond))/s" }
        switch secondsLeft {
        case nil: break
        case let seconds? where seconds < 60: words += ", under a minute left"
        case let seconds?:
            let minutes = (seconds + 59) / 60
            words += ", about \(minutes) minute\(minutes == 1 ? "" : "s") left"
        }
        return words
    }
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
    /// Unix seconds it was approved or declined.
    public let decidedAt: Int64?
    /// Who decided; nil when it was approved at once.
    public let decidedBy: String?
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
            case "downloading":
                let from = switch progress.source {
                case "soulseek": " from Soulseek"
                case "torrent": " by torrent"
                default: ""
                }
                return progress.percent.map { "Downloading\(from), \(Int($0.rounded()))%" } ?? "Downloading\(from)"
            case "transferring":
                return progress.copied.map { "Copying to your server: \($0.words)" } ?? "Copying to your server"
            case "importing": return "Adding to your library"
            case "in_library": return "In your library"
            case "failed": return progress.message.map { "Couldn't be fetched: \($0)" } ?? "Couldn't be fetched"
            default: return progress.message ?? progress.step
            }
        }
    }

    /// The finer points under where it stands: Melete's latest word when it says
    /// more, who decided and when, and when it last changed.
    public func detail(now: Date, locale: Locale = .current) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        func when(_ seconds: Int64) -> String {
            formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seconds)), relativeTo: now)
        }
        var parts: [String] = []
        let step = progress?.step
        if let message = progress?.message, step != "failed", step != "in_library",
           !standing.localizedCaseInsensitiveContains(message) {
            parts.append(message)
        }
        switch (state, decidedBy, decidedAt) {
        case (.requested, _, _): parts.append("Asked \(when(createdAt))")
        case (.approved, let by?, let at?): parts.append("Approved by \(by) \(when(at))")
        case (.approved, nil, let at?): parts.append("Approved \(when(at))")
        case (.declined, let by?, let at?): parts.append("Declined by \(by) \(when(at))")
        default: break
        }
        if let updated = progress?.updatedAt, step != "in_library" {
            parts.append("Updated \(when(updated))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The live feed's newest requests over the list read before: the feed
    /// follows the 50 newest, so older ones stay as the list read them.
    public static func merging(_ live: [MusicRequest], over listed: [MusicRequest]) -> [MusicRequest] {
        guard let oldest = live.map(\.id).min() else { return listed }
        return live + listed.filter { $0.id < oldest }
    }
}
