import Foundation
import JellyfinKit
import UIKit

/// Owns "who are we signed in as, and against which server".
///
/// Deliberately a singleton: the CarPlay scene and the phone UI are separate scenes
/// that must resolve to the *same* session and the same playback engine, so a car
/// screen and a phone screen never disagree about what's playing.
@MainActor
@Observable
final class AppSession {
    static let shared = AppSession()

    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(JellyfinUser)
    }

    private(set) var state: State = .loading
    private(set) var client: JellyfinClient?

    private enum Keys {
        static let deviceId = "jellymusic.deviceId"
        static let serverURL = "jellymusic.serverURL"
        static let userId = "jellymusic.userId"
        static let username = "jellymusic.username"
        static let token = "jellymusic.accessToken"
    }

    private init() {}

    /// A stable per-install identifier. Jellyfin keys playback sessions off this, so
    /// it must survive app launches — regenerating it every launch would litter the
    /// server's dashboard with a new "device" each time.
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: Keys.deviceId) {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: Keys.deviceId)
        return generated
    }

    static var deviceProfile: DeviceProfile {
        DeviceProfile(
            client: "JellyMusic",
            device: UIDevice.current.name,
            deviceId: deviceId,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        )
    }

    // MARK: - Lifecycle

    /// Restores a previous session from disk + keychain. Called once at launch, and
    /// again by the CarPlay scene in case the car connected before the phone UI ran.
    func restore() {
        guard case .loading = state else { return }

        guard
            let urlString = UserDefaults.standard.string(forKey: Keys.serverURL),
            let serverURL = URL(string: urlString),
            let userId = UserDefaults.standard.string(forKey: Keys.userId),
            let username = UserDefaults.standard.string(forKey: Keys.username),
            let token = KeychainStore.get(forKey: Keys.token)
        else {
            state = .signedOut
            return
        }

        let credentials = JellyfinCredentials(
            serverURL: serverURL,
            userId: userId,
            username: username,
            accessToken: token
        )
        let restored = JellyfinClient(serverURL: serverURL, device: Self.deviceProfile)
            .authenticated(as: credentials)
        client = restored
        JellyfinPlaybackBridge.connect(client: restored)
        state = .signedIn(JellyfinUser(id: userId, name: username, serverId: nil))
    }

    func signIn(serverAddress: String, username: String, password: String) async throws {
        let serverURL = try JellyfinClient.normalizeServerURL(serverAddress)
        let anonymous = JellyfinClient(serverURL: serverURL, device: Self.deviceProfile)

        // Probe first: a wrong address should say "that isn't a Jellyfin server"
        // rather than "your password was rejected".
        _ = try await anonymous.systemInfo()

        let (credentials, user) = try await anonymous.signIn(username: username, password: password)

        UserDefaults.standard.set(serverURL.absoluteString, forKey: Keys.serverURL)
        UserDefaults.standard.set(credentials.userId, forKey: Keys.userId)
        UserDefaults.standard.set(credentials.username, forKey: Keys.username)
        KeychainStore.set(credentials.accessToken, forKey: Keys.token)

        let authenticated = anonymous.authenticated(as: credentials)
        client = authenticated
        JellyfinPlaybackBridge.connect(client: authenticated)
        state = .signedIn(user)
    }

    func signOut() async {
        // Stop the music and drop the reporter before the token goes away, so the
        // server doesn't keep showing a session that no longer exists.
        JellyfinPlaybackBridge.disconnect()

        // Tell the server if we can, but never let a network failure trap someone
        // in a signed-in state they're trying to leave.
        try? await client?.signOut()

        KeychainStore.remove(forKey: Keys.token)
        UserDefaults.standard.removeObject(forKey: Keys.serverURL)
        UserDefaults.standard.removeObject(forKey: Keys.userId)
        UserDefaults.standard.removeObject(forKey: Keys.username)

        client = nil
        state = .signedOut
    }
}
