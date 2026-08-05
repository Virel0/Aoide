import Foundation
import Security

/// Minimal keychain wrapper for the one secret this app holds: the Jellyfin access
/// token. It lives here rather than in `UserDefaults` because `UserDefaults` is a
/// plist in the app container — readable from any unencrypted device backup.
enum KeychainStore {
    private static let service = "com.example.jellymusic.credentials"

    /// `afterFirstUnlock` rather than `whenUnlocked`: CarPlay can wake the app and
    /// start playback while the phone is still locked in a pocket, and we need the
    /// token to build stream URLs at that moment.
    ///
    /// Computed rather than stored because the `kSec*` constants are `CFString`,
    /// which Swift 6 won't let us hold in a `static let`.
    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    static func set(_ value: String?, forKey key: String) {
        guard let value else {
            remove(forKey: key)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func remove(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
