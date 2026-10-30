import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import MeleteKit

/// A stand-in Melete inside URLSession: each test names a host of its own and
/// says how that host answers, so tests running at once never share a server.
final class StubServer: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    /// A signed-in client whose requests go to `handler`, on host `host`.
    static func client(host: String, path: String = "", handler: @escaping Handler) -> MeleteClient {
        lock.withLock {
            handlers[host] = handler
            seen[host] = []
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        let url = URL(string: "http://\(host)\(path)")!
        return MeleteClient(
            serverURL: url,
            device: DeviceProfile(client: "Aoide", device: "Test", deviceId: "dev-1", version: "1.0"),
            credentials: MeleteCredentials(serverURL: url, userId: "1", username: "alex", accessToken: "mlt_tok"),
            session: URLSession(configuration: configuration)
        )
    }

    /// What `host` was asked, in order.
    static func requests(to host: String) -> [URLRequest] {
        lock.withLock { seen[host] ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let handler = Self.lock.withLock { () -> Handler? in
            Self.seen[host, default: []].append(request)
            return Self.handlers[host]
        }
        let (status, data) = handler?(request, body) ?? (404, Data(#"{"error":"no stub"}"#.utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Melete's answers, as the stand-in sends them.
enum Fixture {
    static func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    /// A `MusicTrack` with `id` and `title`, the rest plain.
    static func track(_ id: Int, _ title: String, year: Int = 2020, genres: [String] = [], albumId: Int = 1) -> [String: Any] {
        [
            "id": id, "title": title, "artist": "An Artist", "album_id": albumId, "album": "An Album",
            "album_artist": "An Artist", "track_number": 1, "disc_number": 1, "year": year,
            "duration_seconds": 200.0, "genres": genres, "codec": "flac", "bitrate_kbps": 900,
            "sample_rate": 44100, "bit_depth": 16, "channels": 2, "isrc": NSNull(), "liked": false,
            "artists": [["id": 7, "name": "An Artist"]],
        ]
    }

    static func album(_ id: Int, _ title: String, cover: Bool = true) -> [String: Any] {
        [
            "id": id, "title": title, "artist_id": 7, "artist": "An Artist", "year": 2020,
            "tracks": 2, "duration_seconds": 400.0,
            "cover": cover ? "/api/v1/music/albums/\(id)/cover" : NSNull(),
        ]
    }

    static func page(_ items: [[String: Any]], total: Int? = nil) -> Data {
        json(["items": items, "total": total ?? items.count])
    }

    static func session(_ id: Int, _ name: String) -> Data {
        json(["token": "mlt_new", "user": ["id": id, "username": name, "is_admin": false]])
    }
}

extension URLRequest {
    /// A query parameter's value.
    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}
