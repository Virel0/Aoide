import CurationKit
import Foundation
import JellyfinKit

/// CurationKit's `SyncTransport`, spoken over the signed-in Jellyfin connection.
///
/// This is the only place in the app where the sync engine touches a network, and it
/// is deliberately thin — encode, send, decode. Everything that could be decided
/// wrongly was decided in CurationKit against a faithful double; nothing here gets to
/// re-interpret the contract.
///
/// A value type holding a `JellyfinClient`, which is itself a value: signing out
/// produces a *new* client rather than mutating this one, so a transport can never
/// find its credentials changed underneath a request in flight. It is thrown away and
/// rebuilt at every sign-in instead.
struct JellyfinSyncTransport: SyncTransport {
    private let client: JellyfinClient

    init(client: JellyfinClient) {
        self.client = client
    }

    func push(_ request: PushRequest) async throws -> PushResponse {
        let body = try Self.encoder().encode(request)
        let data = try await Self.translatingStatus { try await client.syncPush(body: body) }
        // Kept because a push that answers 200 and acknowledges nothing is the one
        // failure the counts cannot explain: the client can say what it sent and what
        // it understood, but not what the server meant. This is the only place the
        // server's own words exist.
        await SyncDiagnostics.shared.recordPush(sent: request.ops.count, reply: data)
        return try Self.decoder().decode(PushResponse.self, from: data)
    }

    func pull(since cursor: PullCursor?, limit: Int) async throws -> PullResponse {
        let data = try await Self.translatingStatus {
            try await client.syncPull(since: cursor?.value, limit: limit)
        }
        return try Self.decoder().decode(PullResponse.self, from: data)
    }

    /// Turns an HTTP status into the engine's vocabulary.
    ///
    /// CurationKit knows nothing about HTTP on purpose, and the one distinction it
    /// genuinely needs — did the server fail on what I sent, or did the network go
    /// away — is only visible here. Everything else is left as it is and treated as
    /// transient, which is the safe default: retrying a healthy op costs a round trip,
    /// quarantining one because a router blinked costs the change.
    private static func translatingStatus(_ body: () async throws -> Data) async throws -> Data {
        do {
            return try await body()
        } catch let error as JellyfinError {
            if case .http(let status, _, let detail) = error {
                throw SyncTransportFault(status: status, detail: detail)
            }
            throw error
        }
    }

    /// Compact, and that is load-bearing rather than a default we happen to inherit.
    /// The 256 KB payload ceiling is measured on compact text, and `WireOp.make` has
    /// already checked every op against it using the form stored on disk — turning on
    /// `.prettyPrinted` here would push a payload that passed the local check into a
    /// rejection the local check said was impossible.
    ///
    /// Built per call rather than held in a `static let`: these run a handful of times
    /// per sync, and Foundation's coders are not `Sendable`. The existing
    /// `JSONDecoder.jellyfin` does the same.
    private static func encoder() -> JSONEncoder { JSONEncoder() }

    /// A plain decoder, *not* `JSONDecoder.jellyfin`. See `syncPush` for why the
    /// Jellyfin key strategy is actively wrong on this endpoint.
    private static func decoder() -> JSONDecoder { JSONDecoder() }
}
