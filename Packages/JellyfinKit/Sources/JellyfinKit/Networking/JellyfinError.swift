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
        case .http(let status, let path, let detail):
            // The path is named because a server can fail on one route and not
            // another, and "which request" is half the diagnosis — with sync there
            // are exactly two, and knowing whether it broke sending or receiving
            // halves the search before anyone reads a server log.
            detail.map { "\(path) returned an error (HTTP \(status)): \($0)" }
                ?? "\(path) returned an error (HTTP \(status))." 
        case .decoding:
            "The server sent a response this app couldn't read."
        case .transport(let message):
            message
        case .notSignedIn:
            "You're not signed in."
        }
    }
}
