import Foundation

/// The rule the sidecar follows to choose what plays next — `docs/infinity.md`,
/// as arithmetic — written out here so the rule has a reference on the client
/// and a fixture can be generated from it.
///
/// Not what the app runs: the app asks the server (``NextChooser``). This is
/// what the server is *held to*: `NextRankingFixtureTests` runs it over a
/// hand-written library and history and compares every score and factor to
/// the fixture file the sidecar and the desktop also read. Three
/// implementations, one file, and a number that differs is a bug in whichever
/// side is wrong.
///
/// Everything is a plain value so a test can write a library by hand. Nothing
/// here reads a database, asks a server, or looks at a clock: `now` is an
/// input, so "the last ninety days" means the same thing every run.
public enum NextRanking {
    // MARK: - Inputs

    /// One track as the server knows it: its tags and its measurements.
    public struct Record: Equatable, Sendable {
        public var id: String
        /// The same string the history is keyed on: album artist, or the first
        /// artist, or "Unknown Artist".
        public var artist: String
        public var genres: [String]
        public var bpm: Double?
        /// Nil holds: a tempo without a stability figure is taken as steady.
        public var bpmStability: Double?
        public var key: String?
        /// Nil is "no arrangement": the record is unread.
        public var sections: [Section]?

        public init(
            id: String, artist: String, genres: [String],
            bpm: Double? = nil, bpmStability: Double? = nil, key: String? = nil,
            sections: [Section]? = nil
        ) {
            self.id = id
            self.artist = artist
            self.genres = genres
            self.bpm = bpm
            self.bpmStability = bpmStability
            self.key = key
            self.sections = sections
        }

        /// Energy over the whole record, each section weighted by its length.
        public var meanEnergy: Double? {
            guard let sections, !sections.isEmpty else { return nil }
            let length = sections.reduce(0.0) { $0 + max(0, $1.endMs - $1.startMs) }
            guard length > 0 else { return nil }
            return sections.reduce(0.0) { $0 + $1.energy * max(0, $1.endMs - $1.startMs) } / length
        }
    }

    public struct Section: Equatable, Sendable {
        public var startMs: Double
        public var endMs: Double
        public var energy: Double

        public init(startMs: Double, endMs: Double, energy: Double) {
            self.startMs = startMs
            self.endMs = endMs
            self.energy = energy
        }
    }

    /// One decided listen. A play that is neither completed nor skipped is
    /// still in progress and is not a fact about anything yet.
    public struct Play: Equatable, Sendable {
        public var id: String
        public var startedAt: Int64
        public var completed: Bool
        public var skipped: Bool

        public init(id: String, startedAt: Int64, completed: Bool, skipped: Bool) {
            self.id = id
            self.startedAt = startedAt
            self.completed = completed
            self.skipped = skipped
        }
    }

    public struct Library: Equatable, Sendable {
        public var records: [Record]
        public var plays: [Play]
        public var notInterested: Set<String>
        /// The clock, in milliseconds since 1970.
        public var now: Int64

        public init(records: [Record], plays: [Play], notInterested: Set<String>, now: Int64) {
            self.records = records
            self.plays = plays
            self.notInterested = notInterested
            self.now = now
        }
    }

    public struct Query: Equatable, Sendable {
        public var seed: String
        public var queue: [String]
        /// Newest first, as the request sends it.
        public var recent: [String]
        public var mode: NextChooser.Mode
        public var limit: Int

        public init(seed: String, queue: [String], recent: [String], mode: NextChooser.Mode, limit: Int) {
            self.seed = seed
            self.queue = queue
            self.recent = recent
            self.mode = mode
            self.limit = limit
        }
    }

    public struct Result: Equatable, Sendable {
        public var id: String
        public var score: Double
        public var factors: NextChooser.Factors
    }

    // MARK: - The constants, as the contract states them

    public static let tasteWindowMs: Int64 = 90 * 24 * 60 * 60 * 1000
    public static let tasteDepth = 200
    public static let recentDepth = 40
    public static let queueArtistDepth = 3
    public static let minimumFinishSample = 3

    public static let genreWeight = 0.45
    public static let artistWeight = 0.3
    public static let finishWeight = 0.3
    public static let recentPenalty = 1.4
    public static let sameArtistPenalty = 0.4
    public static let similarityWeight = 0.4
    public static let mixabilityWeight = 0.6
    public static let arcWeight = 0.2

    public static let easyBend = 0.02
    public static let maximumBend = 0.06
    public static let steadyEnough = 0.5

    public static let breatherDrop = 0.25
    public static let comebackRise = 0.2

    // MARK: - The ranking

    /// The best `limit` records to follow the seed, best first, and how many
    /// finished plays the taste term stood on.
    public static func rank(_ query: Query, in library: Library) -> (results: [Result], events: Int) {
        let byId = Dictionary(library.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let seed = byId[query.seed] else { return ([], 0) }

        let profile = tasteProfile(library)
        let finish = finishCounts(library.plays)
        let heard = heardLately(query: query, plays: library.plays)
        let heardArtists = artistsHeardLately(heard: heard, query: query, byId: byId)
        let target = arcTarget(query: query, seed: seed, byId: byId)

        let excluded = Set(query.queue).union(query.recent).union([query.seed])
        var results: [Result] = []
        for record in library.records where !excluded.contains(record.id) && !library.notInterested.contains(record.id) {
            let tasteRaw = taste(record, profile: profile, finish: finish[record.id])
            let similarity = similarity(seed: seed, candidate: record)
            let mixability: Double? = nil // no grids in the fixture; pinned by the planner's own table
            let arc = arc(candidate: record, target: target)
            let wasHeard = heard.contains(record.id)
            let sameArtist = heardArtists.contains(record.artist.lowercased())

            var score = tasteRaw + similarity * similarityWeight + arc * arcWeight
            if query.mode == .autodj, let mixability { score += mixability * mixabilityWeight }
            if wasHeard { score -= recentPenalty }
            if sameArtist { score -= sameArtistPenalty }

            results.append(Result(
                id: record.id,
                score: score,
                factors: NextChooser.Factors(
                    taste: min(1, max(0, tasteRaw)),
                    freshness: wasHeard ? 0 : (sameArtist ? 0.5 : 1),
                    similarity: similarity,
                    mixability: mixability,
                    arc: arc
                )
            ))
        }

        results.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.id.utf8.lexicographicallyPrecedes(b.id.utf8)
        }
        return (Array(results.prefix(max(0, query.limit))), profile.events)
    }

    // MARK: - Taste

    struct Profile {
        var genres: [String: Double]
        var artists: [String: Double]
        var events: Int
    }

    /// The latest 200 finished plays within 90 days, counted by genre and by
    /// artist, each normalised against its strongest.
    static func tasteProfile(_ library: Library) -> Profile {
        let byId = Dictionary(library.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let since = library.now - tasteWindowMs
        let finished = library.plays
            .filter { $0.completed && $0.startedAt >= since }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(tasteDepth)

        var genres: [String: Double] = [:]
        var artists: [String: Double] = [:]
        for play in finished {
            guard let record = byId[play.id] else { continue }
            if !record.artist.isEmpty { artists[record.artist.lowercased(), default: 0] += 1 }
            for genre in record.genres where !genre.isEmpty { genres[genre.lowercased(), default: 0] += 1 }
        }
        func normalised(_ counts: [String: Double]) -> [String: Double] {
            guard let top = counts.values.max(), top > 0 else { return [:] }
            return counts.mapValues { $0 / top }
        }
        return Profile(genres: normalised(genres), artists: normalised(artists), events: finished.count)
    }

    /// Decided listens per track, all time.
    static func finishCounts(_ plays: [Play]) -> [String: (starts: Int, completed: Int)] {
        var counts: [String: (starts: Int, completed: Int)] = [:]
        for play in plays where play.completed || play.skipped {
            var entry = counts[play.id] ?? (0, 0)
            entry.starts += 1
            if play.completed { entry.completed += 1 }
            counts[play.id] = entry
        }
        return counts
    }

    static func taste(_ record: Record, profile: Profile, finish: (starts: Int, completed: Int)?) -> Double {
        let genre = record.genres.compactMap { profile.genres[$0.lowercased()] }.max() ?? 0
        let artist = profile.artists[record.artist.lowercased()] ?? 0
        var bias = 0.0
        if let finish, finish.starts >= minimumFinishSample {
            bias = (Double(finish.completed) / Double(finish.starts) - 0.5) * 2 * finishWeight
        }
        return genre * genreWeight + artist * artistWeight + bias
    }

    // MARK: - Freshness

    /// In the request's `recent`, or among the last 40 distinct tracks started
    /// on any device, finished or not.
    static func heardLately(query: Query, plays: [Play]) -> Set<String> {
        var latest: [String: Int64] = [:]
        for play in plays { latest[play.id] = max(latest[play.id] ?? .min, play.startedAt) }
        let lastStarted = latest
            .sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            .prefix(recentDepth)
            .map(\.key)
        return Set(query.recent).union(lastStarted)
    }

    static func artistsHeardLately(heard: Set<String>, query: Query, byId: [String: Record]) -> Set<String> {
        let ids = heard.union(query.queue.suffix(queueArtistDepth))
        return Set(ids.compactMap { byId[$0]?.artist.lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: - Similarity

    /// The mean of the parts that can be answered.
    static func similarity(seed: Record, candidate: Record) -> Double {
        var parts: [Double] = []

        if !seed.genres.isEmpty, !candidate.genres.isEmpty {
            let mine = Set(seed.genres.map { $0.lowercased() })
            parts.append(candidate.genres.contains { mine.contains($0.lowercased()) } ? 1 : 0)
        }

        if let a = steadyTempo(seed), let b = steadyTempo(candidate) {
            var ratio = b / a
            while ratio < 0.7 { ratio *= 2 }
            while ratio > 1.4 { ratio /= 2 }
            parts.append(tempo(rate: ratio))
        }

        parts.append(key(seed.key, candidate.key))

        if let a = seed.meanEnergy, let b = candidate.meanEnergy {
            parts.append(1 - abs(a - b))
        }

        return parts.reduce(0, +) / Double(parts.count)
    }

    static func steadyTempo(_ record: Record) -> Double? {
        guard let bpm = record.bpm, bpm > 0 else { return nil }
        if let stability = record.bpmStability, stability < steadyEnough { return nil }
        return bpm
    }

    /// Free to 2%, gone at 6% — `MixScore.tempo`'s curve.
    static func tempo(rate: Double) -> Double {
        let bend = abs(rate - 1)
        guard bend > easyBend + 1e-9 else { return 1 }
        return max(0, 1 - (bend - easyBend) / (maximumBend - easyBend))
    }

    static func key(_ a: String?, _ b: String?) -> Double {
        guard let a = camelot(a), let b = camelot(b) else { return 0.5 }
        if a.number == b.number { return 1 }
        let distance = abs(a.number - b.number)
        let around = min(distance, 12 - distance)
        return around == 1 && a.isMinor == b.isMinor ? 1 : 0
    }

    /// `BeatGrid.CamelotKey.parse`, kept here so this module stands alone;
    /// the fixture pins the two to each other.
    static func camelot(_ key: String?) -> (number: Int, isMinor: Bool)? {
        guard let key, key.count >= 2 else { return nil }
        let letter = key.suffix(1).uppercased()
        guard letter == "A" || letter == "B" else { return nil }
        guard let number = Int(key.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter == "A")
    }

    // MARK: - Arc

    /// Where the set's energy should go next, or nil when nothing before the
    /// candidate has an arrangement to read.
    static func arcTarget(query: Query, seed: Record, byId: [String: Record]) -> Double? {
        let sequence = Array(query.recent.reversed()) + [query.seed] + query.queue
        let energies = sequence.suffix(4).compactMap { byId[$0]?.meanEnergy }
        guard let reference = energies.last else { return nil }

        let rose = energies.count >= 4 && zip(energies, energies.dropFirst()).allSatisfy { $0 < $1 }
        let fell = energies.count >= 3 && zip(energies.suffix(3), energies.suffix(3).dropFirst()).allSatisfy { $0 > $1 }
        if rose { return reference - breatherDrop }
        if fell { return reference + comebackRise }
        return reference
    }

    static func arc(candidate: Record, target: Double?) -> Double {
        guard let target, let energy = candidate.meanEnergy else { return 0.5 }
        return min(1, max(0, 1 - abs(energy - target)))
    }
}
