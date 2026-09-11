import Foundation
import GRDB

/// What this listener has actually been listening to, as numbers something can
/// sort by.
///
/// Built from the local history rather than from anything the server knows: the
/// server counts a play the moment audio starts, so its idea of a favourite
/// includes everything ever skipped past. This counts listens that finished.
///
/// Deliberately a plain value with no database in it, so the rules that use it
/// can be exercised against a profile written by hand.
public struct TasteProfile: Equatable, Sendable {
    /// Genre to how strongly it figures, 0…1 with the strongest at 1.
    public let genres: [String: Double]
    /// The same for artists.
    public let artists: [String: Double]
    /// Heard recently enough that hearing it again would feel like a repeat.
    public let recent: Set<String>
    /// Whose records those were. A set that plays the same artist twice in a
    /// row has stopped being a set.
    public let recentArtists: Set<String>

    public init(
        genres: [String: Double] = [:],
        artists: [String: Double] = [:],
        recent: Set<String> = [],
        recentArtists: Set<String> = []
    ) {
        self.genres = genres
        self.artists = artists
        self.recent = recent
        self.recentArtists = recentArtists
    }

    public var isEmpty: Bool { genres.isEmpty && artists.isEmpty }
}

/// One song being considered, described by the little that matters here.
public struct TasteCandidate: Equatable, Sendable {
    public let id: String
    public let artist: String
    public let genres: [String]

    public init(id: String, artist: String, genres: [String]) {
        self.id = id
        self.artist = artist
        self.genres = genres
    }
}

/// Puts candidate songs in the order this listener is most likely to want them.
///
/// Not a recommender and not trying to be. Everything here is arithmetic over
/// what the history already says, which means every position it produces can be
/// explained in one sentence — and when it is wrong, it is wrong in a way
/// somebody can point at.
public enum TasteRanking {
    /// How much of the score a familiar genre is worth.
    public static let genreWeight = 0.45
    /// How much a familiar artist is worth. Less than genre, on purpose: a queue
    /// that keeps going should widen out from what is playing rather than stay on
    /// the same four artists all evening.
    public static let artistWeight = 0.3
    /// How far a track's own finish rate can pull it either way.
    public static let finishWeight = 0.3
    /// What it costs to have been heard recently.
    ///
    /// Wider than the whole of the rest of the scale, which puts *everything*
    /// heard lately below *everything* that has not been. Deliberately absolute:
    /// a queue that keeps going has to keep going somewhere new, and a song that
    /// fits perfectly is exactly the song that would otherwise come round every
    /// twenty minutes.
    public static let recentPenalty = 1.4

    /// What it costs to be by an artist heard lately. Smaller than the record's
    /// own penalty, and larger than the artist bonus: the same artist twice in
    /// a row is the one repetition a room notices, and "most similar next"
    /// picks it every time unless something says otherwise.
    public static let sameArtistPenalty = 0.4

    /// How much a record's mixability with the one playing is worth, when a
    /// set is being programmed. Larger than any single taste factor, because
    /// with Auto DJ on the question is not only "would they like this" but
    /// "can it follow *that*" — a record the room would love that cannot be
    /// mixed into what is playing is a record for later.
    public static let compatibilityWeight = 0.6

    public static func score(
        _ candidate: TasteCandidate,
        in profile: TasteProfile,
        finish: FinishCounts?,
        compatibility: Double? = nil
    ) -> Double {
        // The best-matching genre rather than the sum of all of them: a track
        // tagged with six genres is not six times as relevant as one tagged with
        // the right one.
        let genre = candidate.genres.compactMap { profile.genres[$0.lowercased()] }.max() ?? 0
        let artist = profile.artists[candidate.artist.lowercased()] ?? 0

        // A track with too little history is neither promoted nor punished; the
        // sample rule from FinishRate is what decides "too little".
        let finishBias = (finish.flatMap { FinishRate.rate($0) } ?? 0.5) - 0.5

        var score = genre * genreWeight + artist * artistWeight + finishBias * 2 * finishWeight
        if profile.recent.contains(candidate.id) { score -= recentPenalty }
        if profile.recentArtists.contains(candidate.artist.lowercased()) { score -= sameArtistPenalty }
        if let compatibility { score += max(0, min(1, compatibility)) * compatibilityWeight }
        return score
    }

    /// The best `limit` candidates, best first.
    ///
    /// Ties break on id so that the same library and the same history produce the
    /// same queue twice — a list that reshuffles itself between two runs is one
    /// nobody can debug.
    public static func rank(
        _ candidates: [TasteCandidate],
        in profile: TasteProfile,
        finish: [String: FinishCounts] = [:],
        compatibility: [String: Double] = [:],
        limit: Int
    ) -> [TasteCandidate] {
        guard limit > 0 else { return [] }
        var scored: [(candidate: TasteCandidate, score: Double)] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            scored.append((candidate, score(candidate, in: profile, finish: finish[candidate.id], compatibility: compatibility[candidate.id])))
        }
        scored.sort { left, right in
            left.score == right.score ? left.candidate.id < right.candidate.id : left.score > right.score
        }
        return scored.prefix(limit).map(\.candidate)
    }
}

public extension CurationStore {
    /// Reads a profile out of the history.
    ///
    /// - Parameters:
    ///   - since: how far back to count. Taste moves; a year of listening
    ///     describes somebody who no longer exists.
    ///   - depth: how many recent listens to weigh.
    ///   - recentDepth: how many of the most recent to treat as "just heard".
    func tasteProfile(since: Millis = 0, depth: Int = 200, recentDepth: Int = 40) throws -> TasteProfile {
        struct Row: Decodable, FetchableRecord {
            var jellyfinId: String
            var artist: String?
            var genres: String?
        }

        let rows = try read { db in
            try Row.fetchAll(db, sql: """
                SELECT playEvent.jellyfinId AS jellyfinId, track.artist AS artist, track.genres AS genres
                FROM playEvent
                LEFT JOIN track ON track.jellyfinId = playEvent.jellyfinId
                WHERE playEvent.startedAt >= ?
                  AND playEvent.completed = 1
                ORDER BY playEvent.startedAt DESC
                LIMIT ?
                """, arguments: [since, depth])
        }

        var genreCounts: [String: Double] = [:]
        var artistCounts: [String: Double] = [:]
        for row in rows {
            if let artist = row.artist, !artist.isEmpty {
                artistCounts[artist.lowercased(), default: 0] += 1
            }
            guard let genres = row.genres?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: genres)
            else { continue }
            for genre in decoded where !genre.isEmpty {
                genreCounts[genre.lowercased(), default: 0] += 1
            }
        }

        // Normalised against the strongest rather than against the total: what is
        // wanted is "how much of a favourite is this", and a listener with two
        // genres and one with twenty should both have a 1.
        func normalised(_ counts: [String: Double]) -> [String: Double] {
            guard let top = counts.values.max(), top > 0 else { return [:] }
            return counts.mapValues { $0 / top }
        }

        // Everything lately, finished or not: a song skipped an hour ago is still
        // a song you have just heard.
        let recent = try recentlyPlayed(limit: recentDepth)
        let recentArtists = try read { db -> Set<String> in
            guard !recent.isEmpty else { return [] }
            let artists = try String.fetchAll(db, sql: """
                SELECT artist FROM track WHERE jellyfinId IN (\(Self.placeholders(recent.count)))
                """, arguments: StatementArguments(recent))
            return Set(artists.map { $0.lowercased() }.filter { !$0.isEmpty })
        }

        return TasteProfile(
            genres: normalised(genreCounts),
            artists: normalised(artistCounts),
            recent: Set(recent),
            recentArtists: recentArtists
        )
    }
}
