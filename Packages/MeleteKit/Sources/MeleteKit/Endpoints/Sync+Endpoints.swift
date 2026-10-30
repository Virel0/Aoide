import Foundation

/// Aoide's own routes on Melete (`/aoide/*`): sync, the measurements, Next and
/// Discover. They began as a Jellyfin plugin, the sidecar, hence the names here.
///
/// Same origin, same token, no second configuration and no second login. Going
/// through `MeleteClient` rather than assembling URLs by hand is what makes a
/// reverse-proxy subpath work: `serverURL` may already be `https://host/melete`,
/// and `url(path:)` joins onto it.
///
/// These hand back raw bytes instead of decoded models, which is deliberate on two
/// counts. The wire types belong to CurationKit, and MeleteKit does not depend on
/// it. And `JSONDecoder.melete` converts snake_case keys — harmless on Melete's
/// own answers, silent corruption here, where an op payload is opaque client JSON
/// that the server stores verbatim and hands back untouched.
public extension MeleteClient {
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

    /// `GET /aoide/sound-bounds?ids=…`: where the sound starts and stops in each
    /// track the server has measured. At most 200 ids per call.
    func soundBounds(ids: [String]) async throws -> Data {
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return try await send(request("GET", path: Self.soundBoundsPath, query: query), path: Self.soundBoundsPath)
    }

    /// `POST /aoide/sound-bounds`: this device's own measurements, so the server
    /// can serve them without decoding. The body is already-encoded JSON.
    func postSoundBounds(body: Data) async throws -> Data {
        var request = request("POST", path: Self.soundBoundsPath)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, path: Self.soundBoundsPath)
    }

    /// `GET /aoide/audio-analysis?ids=…`: how loud each track is, and its tempo.
    /// At most 200 ids per call. See `docs/audio-analysis.md`.
    func audioAnalysis(ids: [String]) async throws -> Data {
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return try await send(request("GET", path: Self.audioAnalysisPath, query: query), path: Self.audioAnalysisPath)
    }

    /// `GET /aoide/beat-grid?ids=…`: where the beats and bars are, for the tracks
    /// the server has measured. At most 200 ids per call. See `docs/beat-grid.md`.
    ///
    /// No `POST` counterpart, deliberately: a client able to fit its own grid
    /// would not have needed to ask.
    func beatGrids(ids: [String]) async throws -> Data {
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return try await send(request("GET", path: Self.beatGridPath, query: query), path: Self.beatGridPath)
    }

    /// `GET /aoide/arrangement?ids=…`: what each track is made of — sections,
    /// the phrase grid, and where somebody is singing. At most 200 ids per
    /// call. See `docs/arrangement.md`.
    func arrangements(ids: [String]) async throws -> Data {
        let query = [URLQueryItem(name: "ids", value: ids.joined(separator: ","))]
        return try await send(request("GET", path: Self.arrangementPath, query: query), path: Self.arrangementPath)
    }

    /// `POST /aoide/next`: what should play after the record playing, chosen
    /// from the whole library by the server. The body is already-encoded JSON;
    /// the answer comes back as bytes for the same reason the others do. A
    /// `notFound` from this path is an older sidecar, not a missing record —
    /// the server answers 404 for an unknown seed too, and the caller tells
    /// them apart by whether the seed is a track it just played.
    func next(body: Data) async throws -> Data {
        var request = request("POST", path: Self.nextPath)
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, path: Self.nextPath)
    }

    /// `GET /aoide/discover?limit=…`: the records this listener owns and has not
    /// heard through, by taste, the same all week. A `notFound` from this path is
    /// an older sidecar. See `docs/discover.md`.
    func discover(limit: Int) async throws -> Data {
        let query = [URLQueryItem(name: "limit", value: String(limit))]
        return try await send(request("GET", path: Self.discoverPath, query: query), path: Self.discoverPath)
    }

    /// `GET /aoide/analysis/coverage`: how much of the library the server has
    /// measured, and how much of that came out with a beat grid.
    ///
    /// Worth having because measurement is lazy — a track is decoded the first
    /// time something asks about it — so a fresh install sits at nothing
    /// measured, which is correct and looks exactly like a fault.
    func analysisCoverage() async throws -> Data {
        try await send(request("GET", path: Self.coveragePath), path: Self.coveragePath)
    }

    /// `GET /aoide/sync/status`: what the server is and what it will take.
    func syncStatus() async throws -> Data {
        try await send(request("GET", path: Self.statusPath), path: Self.statusPath)
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
    /// 404 is a server without the route; a 405 is a proxy that answered the path itself.
    static func isSidecarAbsent(_ error: any Error) -> Bool {
        switch error as? MeleteError {
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
    private static var statusPath: String { "aoide/sync/status" }
    private static var soundBoundsPath: String { "aoide/sound-bounds" }
    private static var audioAnalysisPath: String { "aoide/audio-analysis" }
    private static var beatGridPath: String { "aoide/beat-grid" }
    private static var coveragePath: String { "aoide/analysis/coverage" }
    private static var arrangementPath: String { "aoide/arrangement" }
    private static var nextPath: String { "aoide/next" }
    private static var discoverPath: String { "aoide/discover" }
    private static var pullPath: String { "aoide/sync/pull" }
}
