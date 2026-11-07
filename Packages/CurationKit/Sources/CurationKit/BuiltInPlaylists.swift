import Foundation

/// Smart playlists every library gets, with the names a listener can form a habit
/// around.
///
/// The brief's point about Discover Weekly is the noun: giving the algorithm a
/// name makes it a feature rather than a black box. These are ordinary smart
/// playlists — rules, not tracks — so they re-run every time they are opened and
/// sync like any other.
///
/// Each user's are made under an id worked out from the built-in and the user
/// (`id(forUser:)`), not minted, which is what lets the phone and the desk each
/// create them on first run and end up with one row, not two: the sync layer
/// merges rows by id. Per user, because Melete gives each playlist id one owner:
/// under one id for everybody (`legacyId`, as before), the first user to sync
/// owned it and every other user's were refused (Melete#324). Aoide for Linux's
/// `built_in.rs` makes the same ids.
public enum BuiltInPlaylist: String, CaseIterable, Sendable {
    case rediscover = "builtin:rediscover"
    case heavyRotation = "builtin:heavy-rotation"

    /// The id this built-in has for the Melete user `userId`.
    public func id(forUser userId: String) -> String { "\(rawValue):\(userId)" }

    /// The id every user's devices once shared. A row under it is moved to the
    /// user's own id (`CurationStore.ensureBuiltInPlaylists`).
    public var legacyId: String { rawValue }

    /// The built-in a playlist is, under its user's id or the old shared one.
    public init?(playlistId: String) {
        guard let built = Self.allCases.first(where: {
            playlistId == $0.rawValue || playlistId.hasPrefix($0.rawValue + ":")
        }) else { return nil }
        self = built
    }

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
