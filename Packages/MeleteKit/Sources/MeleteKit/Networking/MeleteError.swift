import Foundation

public enum MeleteError: Error, Equatable, Sendable {
    case malformedServerURL(String)
    /// Reached something over HTTP, but it didn't answer `/api/v1/health` like a
    /// Melete server would.
    case notAMeleteServer(URL)
    case unauthorized
    /// A right password at sign-in, from a user with two-factor sign-in on:
    /// finish with the code from their authenticator app
    /// (``MeleteClient/finishSignIn(challenge:code:)``), within 5 minutes.
    case secondFactorNeeded(challenge: String)
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

extension MeleteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedServerURL(let raw):
            "\"\(raw)\" isn't a valid server address."
        case .notAMeleteServer(let url):
            "\(url.host() ?? url.absoluteString) responded, but doesn't look like a Melete server."
        case .unauthorized:
            "Your username or password wasn't accepted."
        case .secondFactorNeeded:
            "This account needs the code from its authenticator app to sign in."
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
