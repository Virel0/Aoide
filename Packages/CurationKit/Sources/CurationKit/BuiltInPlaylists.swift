import Foundation

/// Smart playlists every library gets, with the names a listener can form a habit
/// around.
///
/// The brief's point about Discover Weekly is the noun: giving the algorithm a
/// name makes it a feature rather than a black box. These are ordinary smart
/// playlists — rules, not tracks — so they re-run every time they are opened and
/// sync like any other. Their ids are fixed rather than minted, which is what lets
/// the phone and the desk each create them on first run and end up with one row,
/// not two: the sync layer merges rows by id.
public enum BuiltInPlaylist: String, CaseIterable, Sendable {
    case rediscover = "builtin:rediscover"
    case heavyRotation = "builtin:heavy-rotation"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .rediscover: "Rediscover Mix"
        case .heavyRotation: "Heavy Rotation"
        }
    }

    public var notes: String {
        switch self {
        case .rediscover: "Songs you played a lot and haven't heard in six months. Changes as you listen."
        case .heavyRotation: "What you've played most this month."
        }
    }

    /// Both clients must produce exactly these rules; see `BuiltInPlaylistTests`.
    ///
    /// Throws only if `SmartRule`'s validation refuses one of them, which
    /// `BuiltInPlaylistTests` checks for every case — so a bad rule fails a test,
    /// and could never stop the app at launch.
    public var rules: SmartRules {
        get throws {
            // Constructed, never decoded from a string, so a change to `SmartRule`'s
            // validation is caught here at compile time or in the test — not as a
            // playlist that silently stopped matching.
            switch self {
            case .rediscover:
                return try SmartRules(
                    match: .all,
                    rules: [
                        try SmartRule(field: .lastPlayed, op: .notInTheLast, value: .text("-6m")),
                        try SmartRule(field: .playCount, op: .greaterThan, value: .number(2)),
                    ],
                    sort: SmartRules.Sort(field: .playCount, dir: .desc),
                    limit: 40
                )
            case .heavyRotation:
                return try SmartRules(
                    match: .all,
                    rules: [
                        try SmartRule(field: .lastPlayed, op: .inTheLast, value: .text("-1m")),
                        try SmartRule(field: .playCount, op: .greaterThan, value: .number(1)),
                    ],
                    sort: SmartRules.Sort(field: .playCount, dir: .desc),
                    limit: 25
                )
            }
        }
    }
}
