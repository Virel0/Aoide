import Foundation

/// A stateless, `Sendable` handle to one Jellyfin server.
///
/// Signing in produces a *new* client via ``authenticated(as:)`` rather than mutating
/// this one, so a client is safe to hand to any actor and its auth state can never
/// change underneath a request in flight.
public struct JellyfinClient: Sendable {
    public let serverURL: URL
    public let device: DeviceProfile
    public let credentials: JellyfinCredentials?

    private let session: URLSession

    public init(
        serverURL: URL,
        device: DeviceProfile,
        credentials: JellyfinCredentials? = nil,
        session: URLSession = .shared
    ) {
        self.serverURL = serverURL
        self.device = device
        self.credentials = credentials
        self.session = session
    }

    public var isAuthenticated: Bool { credentials != nil }

    /// The signed-in user's id, or a throwing accessor for endpoints that require one.
    public func requireUserId() throws -> String {
        guard let userId = credentials?.userId else { throw JellyfinError.notSignedIn }
        return userId
    }

    public func authenticated(as credentials: JellyfinCredentials) -> JellyfinClient {
        JellyfinClient(
            serverURL: credentials.serverURL,
            device: device,
            credentials: credentials,
            session: session
        )
    }

    public func signedOut() -> JellyfinClient {
        JellyfinClient(serverURL: serverURL, device: device, credentials: nil, session: session)
    }

    // MARK: - Server address normalisation

    /// Turns what someone actually types into a usable base URL.
    ///
    /// Accepts `jellyfin.example.com`, `192.168.1.10:8096`, `https://host/jellyfin/`.
    ///
    /// When no scheme is typed we have to guess one, and the guess has to agree with
    /// App Transport Security or the connection dies before it starts: ATS permits
    /// plain HTTP to local addresses but not to public ones. So a LAN-looking host
    /// gets `http://` and anything else gets `https://`.
    public static func normalizeServerURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JellyfinError.malformedServerURL(raw) }

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
            throw JellyfinError.malformedServerURL(raw)
        }
        return url
    }

    /// Whether a host is one ATS will let us reach over plain HTTP.
    ///
    /// Mirrors what `NSAllowsLocalNetworking` actually covers: loopback, `.local`
    /// (Bonjour), single-label hostnames like `jellyfin`, and the private IPv4
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

    func request(_ method: String, path: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path: path, query: query))
        request.httpMethod = method
        let header = device.headerValue(token: credentials?.accessToken)
        // 10.9+ reads `Authorization`; 10.8 and earlier read `X-Emby-Authorization`.
        request.setValue(header, forHTTPHeaderField: "Authorization")
        request.setValue(header, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: - Transport

    @discardableResult
    func send(_ request: URLRequest, path: String) async throws -> Data {
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
            throw JellyfinError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport("The server sent a malformed response.")
        }

        switch http.statusCode {
        case 200..<300: return data
        case 401: throw JellyfinError.unauthorized
        case 403: throw JellyfinError.forbidden
        case 404: throw JellyfinError.notFound(path: path)
        default:
            // Truncated rather than dropped: an ASP.NET exception page runs to
            // kilobytes, and the first line is the part that names the fault.
            let body = String(decoding: data.prefix(400), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw JellyfinError.http(
                status: http.statusCode,
                path: path,
                detail: body.isEmpty ? nil : body
            )
        }
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
        var request = request("POST", path: path, query: query)
        if let body {
            request.httpBody = try JSONEncoder.jellyfin.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data = try await send(request, path: path)
        return try decode(type, from: data, path: path)
    }

    func postIgnoringResponse(
        path: String,
        query: [URLQueryItem] = [],
        body: (some Encodable)? = Optional<Never>.none
    ) async throws {
        var request = request("POST", path: path, query: query)
        if let body {
            request.httpBody = try JSONEncoder.jellyfin.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        try await send(request, path: path)
    }

    func delete<T: Decodable>(_ type: T.Type = T.self, path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(request("DELETE", path: path, query: query), path: path)
        return try decode(type, from: data, path: path)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder.jellyfin.decode(type, from: data)
        } catch {
            throw JellyfinError.decoding(path: path, underlying: String(describing: error))
        }
    }
}
