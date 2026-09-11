import Foundation

/// The sidecar's answer to "what should play after this?" — see
/// `docs/infinity.md` for what was asked and why.
///
/// The server scores the whole library against the record playing: taste
/// from the finished plays of every device, freshness, similarity, how well
/// each could be mixed in, and where the set's energy has been. It returns
/// the best few, in order, each with the figures that put it there. The
/// client enqueues them as given; the figures are for the queue to show.
public enum NextChooser {
    /// What is sent. `queue` is what is already queued after the seed, in
    /// order; `recent` is what this device heard lately, newest first.
    public struct Request: Encodable, Equatable {
        public var seed: String
        public var queue: [String]
        public var recent: [String]
        public var mode: Mode
        public var limit: Int

        /// The contract's ceilings. Anything past them is dropped from the
        /// far end — the oldest of the recent, the furthest of the queue —
        /// rather than refused, so a long queue never stops the music.
        public static let maxQueue = 1000
        public static let maxRecent = 40

        public init(seed: String, queue: [String], recent: [String], mode: Mode, limit: Int) {
            self.seed = seed
            self.queue = Array(queue.prefix(Self.maxQueue))
            self.recent = Array(recent.prefix(Self.maxRecent))
            self.mode = mode
            self.limit = limit
        }
    }

    public enum Mode: String, Encodable, Equatable {
        case infinity
        case autodj
    }

    public struct Response: Decodable, Equatable {
        public var candidates: [Candidate]
        public var profile: Profile
    }

    public struct Candidate: Decodable, Equatable {
        public var id: String
        public var score: Double
        public var factors: Factors
    }

    /// Why a record was chosen, each in 0…1. `mixability` is absent outside
    /// Auto DJ and for a pair the server could not read.
    public struct Factors: Decodable, Equatable {
        public var taste: Double
        public var freshness: Double
        public var similarity: Double
        public var mixability: Double?
        public var arc: Double

        public init(taste: Double, freshness: Double, similarity: Double, mixability: Double?, arc: Double) {
            self.taste = taste
            self.freshness = freshness
            self.similarity = similarity
            self.mixability = mixability
            self.arc = arc
        }
    }

    /// How much history the taste term stood on. With no finished plays at
    /// all, taste is 0 for everything and the list is the rest of the score.
    public struct Profile: Decodable, Equatable {
        public var events: Int
        public var since: Int64
    }

    public static func encode(_ request: Request) throws -> Data {
        try JSONEncoder().encode(request)
    }

    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }
}

public extension NextChooser.Factors {
    /// One line for a queue row: the figures that put the record there, as
    /// percentages, and a word when freshness cost it something.
    ///
    /// Freshness is left out at 1: the server never returns a record it has
    /// just heard, so nearly every row would read "fresh", which says nothing.
    var summary: String {
        func pct(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        var parts = ["Taste \(pct(taste))", "Fits \(pct(similarity))"]
        if let mixability { parts.append("Mixes \(pct(mixability))") }
        parts.append("Arc \(pct(arc))")
        if freshness < 0.25 {
            parts.append("heard lately")
        } else if freshness < 0.75 {
            parts.append("same artist lately")
        }
        return parts.joined(separator: " · ")
    }
}
