import Foundation

public enum JellyfinError: Error, Equatable, Sendable {
    case malformedServerURL(String)
    /// Reached something over HTTP, but it didn't answer `/System/Info/Public`
    /// like a Jellyfin server would.
    case notAJellyfinServer(URL)
    case unauthorized
    case forbidden
    case notFound(path: String)
    /// `detail` is a short prefix of the response body. Discarding it left a 500
    /// reading only "the server returned an error", which says nothing a person or a
    /// log can act on — and a sidecar failure is exactly where the server's own words
    /// are the whole diagnosis.
    case http(status: Int, path: String, detail: String?)
    case decoding(path: String, underlying: String)
    case transport(String)
    case notSignedIn
}

extension JellyfinError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedServerURL(let raw):
            "\"\(raw)\" isn't a valid server address."
        case .notAJellyfinServer(let url):
            "\(url.host() ?? url.absoluteString) responded, but doesn't look like a Jellyfin server."
        case .unauthorized:
            "Your username or password wasn't accepted."
        case .forbidden:
            "This account isn't allowed to do that."
        case .notFound(let path):
            "The server has no \(path)."
        case .http(let status, _, let detail):
            // The server's own first line, when it gave one. "HTTP 500" alone tells a
            // person nothing they can do and tells whoever reads the log even less.
            detail.map { "The server returned an error (HTTP \(status)): \($0)" }
                ?? "The server returned an error (HTTP \(status))." 
        case .decoding:
            "The server sent a response this app couldn't read."
        case .transport(let message):
            message
        case .notSignedIn:
            "You're not signed in."
        }
    }
}
