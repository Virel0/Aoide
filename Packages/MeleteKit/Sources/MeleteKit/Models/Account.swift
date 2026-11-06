import Foundation

/// `AvatarCategory`: one shelf of the server's profile picture gallery.
public struct AvatarCategory: Decodable, Hashable, Sendable, Identifiable {
    /// `official`, or `gallery/` and the folder's name.
    public let id: String
    /// As shown: "Melete" for Melete's own.
    public let name: String
    public let count: Int
}

/// One picture of the gallery: `id` sets it, `url` shows it.
public struct AvatarPicture: Decodable, Hashable, Sendable, Identifiable {
    public let id: String
    /// Its path on the server, for ``MeleteClient/avatarURL(_:)``.
    public let url: String
}

/// `AvatarPictures`: a page of a category's pictures, and how many it has.
public struct AvatarPicturePage: Decodable, Sendable {
    public let total: Int
    public let pictures: [AvatarPicture]
}

/// `TwoFactorStatus`: whether signing in asks for a code, since when, and
/// the latest changes to it, newest first.
public struct TwoFactorStatus: Decodable, Sendable {
    public let on: Bool
    public let onSince: Date?
    public let changes: [TwoFactorChange]

    enum CodingKeys: String, CodingKey { case on, onSince, changes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decode(Bool.self, forKey: .on)
        onSince = try c.decodeIfPresent(Int64.self, forKey: .onSince).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        changes = try c.decode([TwoFactorChange].self, forKey: .changes)
    }
}

/// One change to two-factor sign-in, or wrong codes typed at sign-in counted
/// together.
public struct TwoFactorChange: Decodable, Hashable, Sendable {
    public enum Kind: String, Decodable, Sendable {
        case turnedOn = "two_factor_on"
        case turnedOff = "two_factor_off"
        case wrongSignInCode = "wrong_sign_in_code"
    }

    /// Where it was made: the user's account, the server's command line, or
    /// signing in (wrong codes).
    public enum Origin: String, Decodable, Sendable {
        case account, server
        case signIn = "sign_in"
    }

    public let change: Kind
    public let madeFrom: Origin
    /// For wrong codes, the latest.
    public let at: Date
    /// 1, except for wrong codes counted together.
    public let count: Int

    public init(change: Kind, madeFrom: Origin, at: Date, count: Int) {
        self.change = change
        self.madeFrom = madeFrom
        self.at = at
        self.count = count
    }

    enum CodingKeys: String, CodingKey { case change, madeFrom, at, count }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        change = try c.decode(Kind.self, forKey: .change)
        madeFrom = try c.decode(Origin.self, forKey: .madeFrom)
        at = Date(timeIntervalSince1970: TimeInterval(try c.decode(Int64.self, forKey: .at)))
        count = try c.decode(Int.self, forKey: .count)
    }
}

/// `TwoFactorSetup`: a new secret for an authenticator app, until a first
/// code confirms it. Shown, never kept: the server's QR drawing of it is not
/// read, since the app draws its own from `uri`.
public struct TwoFactorSetup: Decodable, Sendable {
    /// Base32, no padding, for typing in.
    public let secret: String
    /// `otpauth://totp/…`, for a tap or a QR code.
    public let uri: String
}

/// `PasswordReset`: the password an admin gave a user, shown only once.
public struct GivenPassword: Decodable, Sendable {
    public let username: String
    public let password: String
}
