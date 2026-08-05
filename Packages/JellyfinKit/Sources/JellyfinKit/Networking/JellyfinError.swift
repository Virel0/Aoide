import Foundation

public enum JellyfinError: Error, Equatable, Sendable {
    case malformedServerURL(String)
    /// Reached something over HTTP, but it didn't answer `/System/Info/Public`
    /// like a Jellyfin server would.
    case notAJellyfinServer(URL)
    case unauthorized
    case forbidden
    case notFound(path: String)
    case http(status: Int, path: String)
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
        case .http(let status, _):
            "The server returned an error (HTTP \(status))."
        case .decoding:
            "The server sent a response this app couldn't read."
        case .transport(let message):
            message
        case .notSignedIn:
            "You're not signed in."
        }
    }
}
