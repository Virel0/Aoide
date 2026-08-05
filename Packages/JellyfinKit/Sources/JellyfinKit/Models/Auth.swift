import Foundation

/// `GET /System/Info/Public` — unauthenticated, so it doubles as our "is this
/// actually a Jellyfin server?" probe during login.
public struct PublicSystemInfo: Codable, Sendable {
    public let id: String?
    public let serverName: String
    public let version: String
    public let startupWizardCompleted: Bool?

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? "Jellyfin"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "unknown"
        startupWizardCompleted = try c.decodeIfPresent(Bool.self, forKey: .startupWizardCompleted)
    }
}

public struct JellyfinUser: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let serverId: String?

    /// For rebuilding a user from persisted fields at launch, without a round trip.
    public init(id: String, name: String, serverId: String? = nil) {
        self.id = id
        self.name = name
        self.serverId = serverId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        serverId = try c.decodeIfPresent(String.self, forKey: .serverId)
    }
}

/// `POST /Users/AuthenticateByName` response.
public struct AuthenticationResult: Codable, Sendable {
    public let user: JellyfinUser
    public let accessToken: String
    public let serverId: String?
}

/// Request body for `POST /Users/AuthenticateByName`. Jellyfin expects PascalCase
/// here and names the password field `Pw`.
struct AuthenticateByNameRequest: Encodable {
    let username: String
    let pw: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}

/// Everything needed to talk to a server as a signed-in user. The access token is
/// the secret here — persistence belongs in the keychain, never `UserDefaults`.
public struct JellyfinCredentials: Hashable, Sendable {
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

/// Identifies this install to the server. Jellyfin shows `client`/`device` in its
/// active-devices dashboard, and keys playback sessions off `deviceId`.
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

    /// Value for the `Authorization` header. Jellyfin 10.8 and earlier read this from
    /// `X-Emby-Authorization`; 10.9+ reads `Authorization`. We send both.
    func headerValue(token: String?) -> String {
        var parts = [
            "Client=\"\(Self.escape(client))\"",
            "Device=\"\(Self.escape(device))\"",
            "DeviceId=\"\(Self.escape(deviceId))\"",
            "Version=\"\(Self.escape(version))\"",
        ]
        if let token { parts.append("Token=\"\(Self.escape(token))\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    /// The header is a quoted-string list, so an unescaped `"` in a device name
    /// (iOS lets you name a phone anything) would corrupt every request.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
