import Foundation

/// What the listener was doing while a track played.
///
/// A closed set on purpose, and the same four words the desktop uses: the point
/// of the tag is to be asked about later — "the tracks I finish while gaming" is
/// a far better predicate than any genre — and a free-text field would make that
/// question unanswerable within a week.
///
/// Written onto a play event when the listen *begins*, so a session that ends
/// mid-track leaves that track tagged as what it was started during. Nothing
/// detects it; somebody says so.
public enum Activity: String, Codable, CaseIterable, Sendable {
    case gaming
    case focus
    case chores
    case commute

    public var displayName: String {
        switch self {
        case .gaming: "Gaming"
        case .focus: "Focus"
        case .chores: "Chores"
        case .commute: "Commute"
        }
    }

    public var symbolName: String {
        switch self {
        case .gaming: "gamecontroller"
        case .focus: "brain.head.profile"
        case .chores: "house"
        case .commute: "car"
        }
    }

    /// Anything outside the set is dropped rather than stored.
    ///
    /// Play events sync, so a row written by a newer build carrying a word this
    /// one has never heard of will arrive here. Keeping it would put a value in
    /// the column that no query can interpret; dropping it loses one tag.
    public static func parse(_ raw: String?) -> Activity? {
        guard let raw else { return nil }
        return Activity(rawValue: raw)
    }
}
