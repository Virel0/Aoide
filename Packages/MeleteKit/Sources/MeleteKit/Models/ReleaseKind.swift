import Foundation

/// What kind of release an album is, for the heading it goes under on its
/// artist's page, in the order the headings come.
///
/// Melete gives an album its MusicBrainz release group's types (`primary_type`,
/// `secondary_types`), and its web groups an artist's albums by them; this is
/// the same rule. Aoide for Linux follows it too.
public enum ReleaseKind: String, Codable, CaseIterable, Sendable {
    case albums
    case singles
    case live
    case compilations

    /// The heading the kind goes under.
    public var title: String {
        switch self {
        case .albums: "Albums"
        case .singles: "Singles & EPs"
        case .live: "Live"
        case .compilations: "Compilations"
        }
    }

    /// The kind of an album: Live and Compilations by its secondary types (or,
    /// for a compilation, its tags), Singles & EPs by its primary type, the rest
    /// Albums.
    ///
    /// An album not matched to MusicBrainz has no type at all. Then the length
    /// stands in, as it did before Melete gave types: 3 tracks or fewer is a
    /// single or EP.
    public static func of(
        primaryType: String?, secondaryTypes: [String], compilation: Bool, tracks: Int?
    ) -> ReleaseKind {
        if secondaryTypes.contains("Live") { return .live }
        if compilation || secondaryTypes.contains("Compilation") { return .compilations }
        if let primaryType {
            return ["Single", "EP"].contains(primaryType) ? .singles : .albums
        }
        if secondaryTypes.isEmpty, let tracks, tracks <= 3 { return .singles }
        return .albums
    }

    /// `albums` under their kinds, in the kinds' order, leaving out a kind with
    /// none. An album whose kind isn't known counts as one of `albums`.
    public static func grouped(_ albums: [MusicItem]) -> [(kind: ReleaseKind, albums: [MusicItem])] {
        allCases.compactMap { kind in
            let these = albums.filter { ($0.releaseKind ?? .albums) == kind }
            return these.isEmpty ? nil : (kind, these)
        }
    }
}
