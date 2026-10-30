import Foundation

/// `GET /api/v1/health` — unauthenticated, so it doubles as our "is this really a
/// Melete server?" probe before a password is sent anywhere.
public struct ServerInfo: Codable, Sendable {
    /// `ok` on a server that's up.
    public let status: String
    /// Melete's version, such as `0.1.0`.
    public let version: String
}

/// A user of the server, by id and name: who is signed in, or whom to share with.
public struct MeleteUser: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name = "username"
    }

    /// Melete's ids are numbers; the app keeps every id as text.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = String(try c.decode(Int64.self, forKey: .id))
        name = try c.decode(String.self, forKey: .name)
    }
}

/// `LoginResponse`: the session token, shown only here, and who it signs in.
struct Session: Decodable {
    let token: String
    let user: MeleteUser
}

struct LoginRequest: Encodable {
    let username: String
    let password: String
    let deviceName: String
}

/// What Quick Connect shows while it waits: the `code` for the person to approve
/// in Melete's web UI, and the `secret` only this device polls with.
public struct QuickConnectCode: Decodable, Hashable, Sendable {
    /// Shown on screen, to be typed into the web UI.
    public let code: String
    /// Sent with each poll; never shown.
    public let secret: String
    /// Seconds until the code runs out.
    public let expiresIn: Int
}

public struct MeleteCredentials: Hashable, Sendable {
    public let serverURL: URL
    public let userId: String
    public let username: String
    public let accessToken: String

    public init(serverURL: URL, userId: String, username: String, accessToken: String) {
        self.serverURL = serverURL
        self.userId = userId
        self.username = username
        self.accessToken = accessToken
    }
}

/// This install, as the server's device list shows it.
public struct DeviceProfile: Hashable, Sendable {
    public let client: String
    public let device: String
    public let deviceId: String
    public let version: String

    public init(client: String, device: String, deviceId: String, version: String) {
        self.client = client
        self.device = device
        self.deviceId = deviceId
        self.version = version
    }

    /// The name sign-in sends: Melete takes 1 to 100 characters, so a blank name
    /// becomes the client's and a long one is cut.
    var signInName: String {
        let name = device.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? client : name).prefix(100))
    }
}
