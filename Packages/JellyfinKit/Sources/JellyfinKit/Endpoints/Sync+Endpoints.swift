import Foundation

/// The curation sidecar, which lives on the Jellyfin host.
///
/// Same origin, same `MediaBrowser Token`, no second configuration and no second
/// login — that is the whole reason it was built as a Jellyfin plugin rather than a
/// service. Going through `JellyfinClient` rather than assembling URLs by hand is
/// what makes a reverse-proxy subpath work: `serverURL` may already be
/// `https://host/jellyfin`, and `url(path:)` joins onto it.
///
/// These hand back raw bytes instead of decoded models, which is deliberate on two
/// counts. The wire types belong to CurationKit, and JellyfinKit does not depend on
/// it. And `JSONDecoder.jellyfin` lowercases the first character of every key to
/// paper over Jellyfin's own PascalCase/camelCase inconsistency — harmless on
/// Jellyfin's models, silent corruption here, where an op payload is opaque client
/// JSON that the server stores verbatim and hands back untouched. A field named
/// `Notes` would arrive as `notes` and the row would sync into a different shape than
/// it left.
public extension JellyfinClient {
    /// `POST /aoide/sync/push`. The body is already-encoded JSON.
    ///
    /// Safe to repeat: the server's idempotency is on `(user, opId)`, so a push that
    /// timed out somewhere unknowable can simply be sent again.
    func syncPush(body: Data) async throws -> Data {
        var request = request("POST", path: Self.pushPath)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, path: Self.pushPath)
    }

    /// `GET /aoide/sync/pull`.
    ///
    /// `since` is always sent, as zero on a device that has never synced.
    ///
    /// It used to be omitted, on the reasoning that a cursor is a position and there
    /// is no honest position meaning "the beginning". That is true and it is also the
    /// client being clever at the server's expense: every example in the contract
    /// carries the parameter, sequence numbers start above zero so `since=0` is
    /// unambiguous, and a server that binds it as required fails on the one request a
    /// brand-new device makes first — which is indistinguishable, from here, from the
    /// sidecar being broken.
    func syncPull(since cursor: Int64?, limit: Int) async throws -> Data {
        let query = Self.pullQuery(since: cursor, limit: limit)
        return try await send(request("GET", path: Self.pullPath, query: query), path: Self.pullPath)
    }

    /// Whether an error means this server has no sidecar, as opposed to a sync that
    /// failed and should be tried again.
    ///
    /// Worth telling apart because they need opposite words in front of a listener:
    /// one is "your server can't do this yet" and the other is "not right now". A
    /// 404 is the plugin missing; a 405 is a proxy that answered the path itself.
    static func isSidecarAbsent(_ error: any Error) -> Bool {
        switch error as? JellyfinError {
        case .notFound: true
        case .http(let status, _, _): status == 405 || status == 501
        default: false
        }
    }

    /// Split out so the query can be asserted without a server.
    static func pullQuery(since cursor: Int64?, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "since", value: String(cursor ?? 0)),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    private static var pushPath: String { "aoide/sync/push" }
    private static var pullPath: String { "aoide/sync/pull" }
}
