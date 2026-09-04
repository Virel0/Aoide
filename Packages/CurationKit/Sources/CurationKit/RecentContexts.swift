import Foundation

/// Something a listener was *in*: an album, a playlist, a station — the things a
/// session starts from, as opposed to the songs it contains.
///
/// Kept so Home can open on the last few of them and resume any in one tap. The
/// brief this follows is blunt about it: most sessions should start in one tap,
/// and that beats a beautiful empty state. Local to the device on purpose — what
/// the desk was in is not what the phone was in, and the queue handover already
/// covers "carry on from the other one".
public struct RecentContext: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case album
        case jellyfinPlaylist
        case localPlaylist
        case station
    }

    public var kind: Kind
    /// The album, playlist or seed item id, in whichever store the kind names.
    public var id: String
    public var name: String
    public var subtitle: String?
    /// A Jellyfin item whose primary image stands for this context, if any.
    public var artworkItemId: String?
    public var lastOpened: Millis

    public init(kind: Kind, id: String, name: String, subtitle: String? = nil, artworkItemId: String? = nil, lastOpened: Millis) {
        self.kind = kind
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.artworkItemId = artworkItemId
        self.lastOpened = lastOpened
    }

    /// One entry per thing, whatever its name is today.
    public var key: String { "\(kind.rawValue):\(id)" }
}

/// The recent contexts, newest first, one per thing, bounded.
public struct RecentContextList: Codable, Equatable, Sendable {
    /// More than a Home screen will ever show; enough that a busy week of
    /// listening does not push the album from Monday out before the weekend.
    public static let capacity = 24

    public private(set) var contexts: [RecentContext] = []

    public init(contexts: [RecentContext] = []) {
        self.contexts = contexts
    }

    /// Records a visit. The same thing opened again moves to the front and takes
    /// the new name and artwork; nothing is ever listed twice.
    public mutating func remember(_ context: RecentContext) {
        contexts.removeAll { $0.key == context.key }
        contexts.insert(context, at: 0)
        if contexts.count > Self.capacity {
            contexts.removeLast(contexts.count - Self.capacity)
        }
    }

    public mutating func forget(key: String) {
        contexts.removeAll { $0.key == key }
    }

    /// The most recent `limit`, newest first.
    public func latest(_ limit: Int) -> [RecentContext] {
        Array(contexts.prefix(max(0, limit)))
    }
}
