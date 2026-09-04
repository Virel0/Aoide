import Foundation

/// The tables that sync, and the two names each of them has.
///
/// The names differ, and translating between them at the wire boundary is cheaper
/// than agreeing on one: GRDB's tables are singular camelCase because the record
/// types are, and the sidecar's allow-list is plural snake_case because its author
/// wrote SQL. Rewriting every stored `op` row to spell its entity the server's way
/// would be a schema migration in service of a formatting preference, and it would
/// still leave ops written by an older build spelling it the old way. Matching on
/// the server is strict and case-sensitive, so these six strings *are* the contract.
public enum SyncEntity: String, CaseIterable, Hashable, Sendable {
    case playlist
    case playlistItem
    case folder
    case like
    case playEvent
    case queueState
    case trackFlags

    // `track` is absent on purpose, and its absence is the enforcement rather than a
    // rule written down somewhere. The track cache is per-device — every device
    // rebuilds it from its own Jellyfin connection — so the server refuses the
    // entity outright. With no case to name it, an op for `track` cannot be turned
    // into a wire op at all; the only thing the push path can do with one is
    // quarantine it, which is what `WireOp.make` does.

    /// The GRDB table name, which is also this enum's raw value.
    public var localTable: String { rawValue }

    /// The name in the sidecar's allow-list.
    public var wireName: String {
        switch self {
        case .playlist: "playlists"
        case .playlistItem: "playlist_items"
        case .folder: "folders"
        case .like: "likes"
        case .playEvent: "play_events"
        case .queueState: "queue_state"
        case .trackFlags: "track_flags"
        }
    }

    /// Entities a server may not know yet.
    ///
    /// The sidecar's entity list is an allow-list and an unknown name is refused,
    /// which by the contract would quarantine the op — real user data lost to a
    /// deployment order. Ops for these are held locally instead until the server
    /// advertises the entity in `/aoide/sync/status`. Everything older than the
    /// advertisement itself is assumed accepted.
    public var needsServerSupport: Bool {
        self == .trackFlags
    }

    public init?(localTable: String) {
        self.init(rawValue: localTable)
    }

    /// `nil` for a name this build has never heard of — a newer client syncing an
    /// entity that did not exist when this one shipped. The caller quarantines it;
    /// nothing here traps.
    public init?(wireName: String) {
        guard let match = Self.byWireName[wireName] else { return nil }
        self = match
    }

    private static let byWireName: [String: SyncEntity] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.wireName, $0) })

    /// The field inside the payload that has to equal the op's `entityId`.
    ///
    /// The server never parses payloads, so a disagreement between the two syncs
    /// happily and then confuses every reader afterwards — this is the one identity
    /// rule nothing upstream can enforce. `queueState` is the odd one out: that table
    /// is keyed by the device rather than by a UUID, so its identity lives in
    /// `deviceId` and there is no `id` field to compare at all.
    public var identityKey: String {
        self == .queueState ? "deviceId" : "id"
    }

    /// Append-only tables carry no `updatedAt` and settle no conflicts: an event is
    /// written once and at most amended once, by the same device, so the merge asks
    /// which copy is the more complete rather than which write was later. The
    /// amendment is not a loophole — see `InboundApplier.appendEvent` for why it has
    /// to travel and what happens to play counts when it does not.
    public var isAppendOnly: Bool {
        self == .playEvent
    }
}
