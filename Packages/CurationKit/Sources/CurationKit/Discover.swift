import Foundation

/// The sidecar's weekly Discover list — see `docs/discover.md` and the
/// sidecar's own contract. The server chooses; the client shows.
public enum Discover {
    public static let limit = 30

    public struct Response: Decodable, Equatable, Sendable {
        /// The ISO week the list belongs to, in UTC: "2026-W43".
        public var week: String
        public var candidates: [Candidate]
        public var profile: Profile
    }

    public struct Candidate: Decodable, Equatable, Sendable {
        public var id: String
        public var score: Double
        /// Only taste is measured; the server sends the other five factors as
        /// null or 1 and there is nothing to show of them.
        public var taste: Double

        enum CodingKeys: String, CodingKey { case id, score, factors }
        enum FactorKeys: String, CodingKey { case taste }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            score = try c.decode(Double.self, forKey: .score)
            let factors = try c.nestedContainer(keyedBy: FactorKeys.self, forKey: .factors)
            taste = try factors.decode(Double.self, forKey: .taste)
        }
    }

    public struct Profile: Decodable, Equatable, Sendable {
        public var events: Int
        public var since: Int64
    }

    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    /// The ISO week of `date` in UTC, spelled as the server spells it. The list
    /// is fetched again when this stops matching the one held — Monday 00:00
    /// UTC, on every device at once.
    public static func week(of date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .gmt
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
    }
}
