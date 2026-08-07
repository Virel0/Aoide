import Foundation
import Testing
@testable import JellyfinKit

/// The sidecar's requests, checked at the point where they are still inspectable.
///
/// Everything here is the kind of mistake that produces a 404 nobody can explain: a
/// path assembled by hand that ignores a reverse-proxy subpath, a token that goes to
/// Jellyfin's endpoints but not to this one, a cursor sent when there isn't one.
@Suite("Sidecar requests")
struct SyncEndpointTests {
    private func client(_ address: String) throws -> JellyfinClient {
        let url = try JellyfinClient.normalizeServerURL(address)
        return JellyfinClient(
            serverURL: url,
            device: DeviceProfile(client: "Aoide", device: "iPhone", deviceId: "dev-1", version: "1.0")
        ).authenticated(as: JellyfinCredentials(
            serverURL: url, userId: "u1", username: "alex", accessToken: "tok-123"
        ))
    }

    @Test("the sidecar hangs off the server root")
    func rootPath() throws {
        let request = try client("https://media.example.com").request("POST", path: "aoide/sync/push")
        #expect(request.url?.absoluteString == "https://media.example.com/aoide/sync/push")
    }

    /// The reason to go through the client at all rather than build a URL: a Jellyfin
    /// behind a reverse proxy lives at a subpath, and the sidecar lives under it too.
    @Test("a reverse-proxy subpath is preserved")
    func subpathPreserved() throws {
        let request = try client("https://example.com/jellyfin").request("GET", path: "aoide/sync/pull")
        #expect(request.url?.absoluteString == "https://example.com/jellyfin/aoide/sync/pull")
    }

    @Test("the sidecar gets the same MediaBrowser token as everything else")
    func carriesTheToken() throws {
        let request = try client("https://media.example.com").request("POST", path: "aoide/sync/push")
        let header = request.value(forHTTPHeaderField: "Authorization")
        #expect(header?.hasPrefix("MediaBrowser ") == true)
        #expect(header?.contains("Token=\"tok-123\"") == true)
        // 10.8 and earlier read the other one; both are sent everywhere else too.
        #expect(request.value(forHTTPHeaderField: "X-Emby-Authorization") == header)
    }

    @Test("a device that has synced before asks from where it left off")
    func pullCarriesCursor() throws {
        let url = try client("https://media.example.com")
            .url(path: "aoide/sync/pull", query: [
                URLQueryItem(name: "since", value: "12400"),
                URLQueryItem(name: "limit", value: "500"),
            ])
        #expect(url.query() == "since=12400&limit=500")
    }

    /// Not `since=0`. A cursor is a sequence number, not a count, and the only honest
    /// way to say "from the beginning of the log" is to name no position at all.
    @Test("a device that has never synced names no position")
    func pullWithoutCursor() throws {
        let url = try client("https://media.example.com")
            .url(path: "aoide/sync/pull", query: [URLQueryItem(name: "limit", value: "500")])
        #expect(url.query() == "limit=500")
    }

    /// A brand-new device makes this request first, and a server that binds `since`
    /// as required answers it with a 500 — which reads from here as the sidecar being
    /// broken rather than as one missing parameter.
    @Test("a device that has never synced still names a position")
    func firstPullNamesZero() async throws {
        let query = JellyfinClient.pullQuery(since: nil, limit: 500)
        #expect(query.contains { $0.name == "since" && $0.value == "0" })
        #expect(query.contains { $0.name == "limit" && $0.value == "500" })
    }

    @Test("a stored cursor is sent as itself")
    func laterPullsSendTheCursor() {
        let query = JellyfinClient.pullQuery(since: 12_345, limit: 250)
        #expect(query.contains { $0.name == "since" && $0.value == "12345" })
    }

    /// "HTTP 500" alone tells a person nothing to act on, and a sidecar failure is
    /// exactly where the server's own words are the whole diagnosis.
    @Test("the server's own message reaches the listener")
    func errorCarriesDetail() {
        let described = JellyfinError.http(
            status: 500, path: "aoide/sync/push", detail: "NullReferenceException in SyncController"
        ).errorDescription
        #expect(described?.contains("500") == true)
        #expect(described?.contains("NullReferenceException") == true)
        // Which of the two sync calls broke is half the diagnosis.
        #expect(described?.contains("aoide/sync/push") == true)
    }

    @Test("an error with no body still reads as a sentence")
    func errorWithoutDetail() {
        let described = JellyfinError.http(status: 503, path: "aoide/sync/pull", detail: nil).errorDescription
        #expect(described == "aoide/sync/pull returned an error (HTTP 503).")
    }

    // MARK: - Telling "no sidecar" from "not right now"

    @Test("a missing plugin is not a failure to retry")
    func absentSidecar() {
        #expect(JellyfinClient.isSidecarAbsent(JellyfinError.notFound(path: "aoide/sync/push")))
        #expect(JellyfinClient.isSidecarAbsent(JellyfinError.http(status: 405, path: "aoide/sync/push", detail: nil)))
    }

    @Test("a server that is merely down is worth trying again")
    func transientFailures() {
        #expect(!JellyfinClient.isSidecarAbsent(JellyfinError.transport("offline")))
        #expect(!JellyfinClient.isSidecarAbsent(JellyfinError.http(status: 502, path: "aoide/sync/pull", detail: nil)))
        #expect(!JellyfinClient.isSidecarAbsent(JellyfinError.unauthorized))
    }
}
