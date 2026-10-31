import Foundation
// URLSession and friends live in a separate module on Linux. The guard costs
// nothing on Apple platforms and is the whole difference between this package
// being portable and not.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stateless, `Sendable` handle to one Melete server.
///
/// Signing in produces a *new* client via ``authenticated(as:)`` rather than mutating
/// this one, so a client is safe to hand to any actor and its auth state can never
/// change underneath a request in flight.
///
/// Aoide's own routes (`/aoide/*`: sync, Next, Discover, the measurements) are on
/// the same server and token; `Sync+Endpoints.swift` speaks them.
public struct MeleteClient: Sendable {
    public let serverURL: URL
    public let device: DeviceProfile
    public let credentials: MeleteCredentials?

    private let session: URLSession

    public init(
        serverURL: URL,
        device: DeviceProfile,
        credentials: MeleteCredentials? = nil,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.device = device
        self.credentials = credentials
        self.session = session
    }

    public var isAuthenticated: Bool { credentials != nil }

    /// The signed-in user's id, or a throwing accessor for calls that require one.
    public func requireUserId() throws -> String {
        guard let userId = credentials?.userId else { throw MeleteError.notSignedIn }
        return userId
    }

    public func authenticated(as credentials: MeleteCredentials) -> MeleteClient {
        MeleteClient(
            serverURL: credentials.serverURL,
            device: device,
            credentials: credentials,
            session: session
        )
    }

    public func signedOut() -> MeleteClient {
        MeleteClient(serverURL: serverURL, device: device, credentials: nil, session: session)
    }

    /// The `Authorization` header value for a request made outside this client,
    /// such as a cover download; `nil` when signed out.
    public var authorization: String? {
        credentials.map { "Bearer \($0.accessToken)" }
    }

    // MARK: - Server address normalisation

    /// Turns what someone actually types into a usable base URL.
    ///
    /// Accepts `melete.example.com`, `192.168.1.10:8100`, `https://host/melete/`.
    ///
    /// When no scheme is typed we have to guess one, and the guess has to agree with
    /// App Transport Security or the connection dies before it starts: ATS permits
    /// plain HTTP to local addresses but not to public ones. So a LAN-looking host
    /// gets `http://` and anything else gets `https://`.
    public static func normalizeServerURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeleteError.malformedServerURL(raw) }

        let withScheme: String
        if trimmed.contains("://") {
            withScheme = trimmed
        } else {
            let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
            withScheme = (isLocalHost(host) ? "http://" : "https://") + trimmed
        }

        // Strip trailing slashes so path joining stays predictable.
        var cleaned = withScheme
        while cleaned.hasSuffix("/") { cleaned.removeLast() }

        guard
            let components = URLComponents(string: cleaned),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host,
            !host.isEmpty,
            let url = components.url
        else {
            throw MeleteError.malformedServerURL(raw)
        }
        return url
    }

    /// Whether a host is one ATS will let us reach over plain HTTP.
    ///
    /// Mirrors what `NSAllowsLocalNetworking` actually covers: loopback, `.local`
    /// (Bonjour), single-label hostnames like `melete`, and the private IPv4
    /// ranges. Anything else is a public name and must go over TLS.
    static func isLocalHost(_ hostAndPort: String) -> Bool {
        let host = hostAndPort.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        guard !host.isEmpty else { return false }

        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        if host.hasSuffix(".local") { return true }
        // No dot at all — a bare LAN hostname, never a public domain.
        if !host.contains(".") { return true }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        case (169, 254): return true  // link-local
        default: return false
        }
    }

    // MARK: - Request building

    func url(path: String, query: [URLQueryItem] = []) -> URL {
        var url = serverURL
        for segment in path.split(separator: "/") {
            url.append(path: String(segment))
        }
        if !query.isEmpty {
            url.append(queryItems: query)
        }
        return url
    }

    /// A path the server handed out (`/api/v1/music/stream/…`) beneath the server
    /// address, so a reverse proxy's prefix is kept. `nil` for anything but a plain
    /// absolute path: another host (`//…`), a dot segment, a query.
    func url(servedPath path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        let plain = segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
                && !segment.contains(where: { "?#\\".contains($0) })
        }
        return plain ? url(path: String(path.dropFirst())) : nil
    }

    func request(_ method: String, path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path: path, query: query))
        request.httpMethod = method
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Transport

    @discardableResult
    func send(_ request: URLRequest, path: String) async throws -> Data {
        try await sendWithStatus(request, path: path).data
    }

    /// ``send(_:path:)`` with the 2xx status too, for the calls that answer
    /// differently by it (Quick Connect's 202 while it waits).
    func sendWithStatus(_ request: URLRequest, path: String) async throws -> (data: Data, status: Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // A cancelled request is not a failure — SwiftUI cancels `.task` every
            // time a view disappears, so this fires constantly during ordinary
            // navigation. Surfacing it as `.transport("cancelled")` let callers
            // cache it as a permanent error and left whole screens dead for the
            // rest of the session.
            if error.code == .cancelled { throw CancellationError() }
            throw MeleteError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw MeleteError.transport("The server sent a malformed response.")
        }

        switch http.statusCode {
        case 200..<300: return (data, http.statusCode)
        case 401: throw Self.secondFactor(data) ?? MeleteError.unauthorized
        case 403: throw MeleteError.forbidden
        case 404: throw MeleteError.notFound(path: path)
        default:
            throw MeleteError.http(status: http.statusCode, path: path, detail: Self.detail(data))
        }
    }

    /// A sign-in's challenge for a two-factor code, when that's what the 401 is.
    static func secondFactor(_ data: Data) -> MeleteError? {
        struct Challenge: Decodable {
            let secondFactor: String
            let challenge: String
        }
        guard let found = try? JSONDecoder.melete.decode(Challenge.self, from: data),
              found.secondFactor == "totp"
        else { return nil }
        return .secondFactorNeeded(challenge: found.challenge)
    }

    /// What went wrong: Melete's `{"error": …}` message, or else a short prefix of
    /// the body (a proxy's error page runs to kilobytes).
    static func detail(_ data: Data) -> String? {
        struct Shape: Decodable { let error: String }
        let text = (try? JSONDecoder().decode(Shape.self, from: data))?.error
            ?? String(decoding: data.prefix(400), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(400))
    }

    func get<T: Decodable>(_ type: T.Type = T.self, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(request("GET", path: path, query: query), path: path)
        return try decode(type, from: data, path: path)
    }

    func post<T: Decodable>(
        _ type: T.Type = T.self,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<Never>.none
    ) async throws -> T {
        let data = try await send(try jsonRequest("POST", path: path, query: query, body: body), path: path)
        return try decode(type, from: data, path: path)
    }

    /// A request whose answer has no body worth reading (most are 204).
    func sendIgnoringResponse(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<Never>.none
    ) async throws {
        try await send(try jsonRequest(method, path: path, query: query, body: body), path: path)
    }

    func jsonRequest(
        _ method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)?
    ) throws -> URLRequest {
        var request = request(method, path: path, query: query)
        if let body {
            request.httpBody = try JSONEncoder.melete.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder.melete.decode(type, from: data)
        } catch {
            throw MeleteError.decoding(path: path, underlying: String(describing: error))
        }
    }
}
