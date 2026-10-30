import Foundation
import Security
import os

/// Minimal keychain wrapper for the one secret this app holds: the Melete access
/// token. It lives here rather than in `UserDefaults` because `UserDefaults` is a
/// plist in the app container — readable from any unencrypted device backup.
enum KeychainStore {
    private static let service = AppIdentity.named("credentials")
    private static let log = Logger(subsystem: AppIdentity.bundle, category: "keychain")

    /// `afterFirstUnlock` rather than `whenUnlocked`: CarPlay can wake the app and
    /// start playback while the phone is still locked in a pocket, and we need the
    /// token to build stream URLs at that moment.
    ///
    /// Computed rather than stored because the `kSec*` constants are `CFString`,
    /// which Swift 6 won't let us hold in a `static let`.
    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlock }

    /// Stores a value, reporting whether it actually landed.
    ///
    /// The status is returned rather than swallowed because a silent failure here
    /// is indistinguishable from success right up until the next launch, when the
    /// user is mysteriously signed out again.
    @discardableResult
    static func set(_ value: String?, forKey key: String) -> Bool {
        guard let value else {
            remove(forKey: key)
            return true
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: accessibility,
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            log.error("Keychain write for \(key, privacy: .public) failed: \(describe(status), privacy: .public)")
            return false
        }
        return true
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
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            // Ordinary on a first launch or after signing out — not worth logging
            // as an error.
            return nil
        default:
            log.error("Keychain read for \(key, privacy: .public) failed: \(describe(status), privacy: .public)")
            return nil
        }
    }

    static func remove(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            log.error("Keychain delete for \(key, privacy: .public) failed: \(describe(status), privacy: .public)")
        }
    }

    /// `OSStatus` alone is an opaque number in a log; `-34018` in particular means
    /// "missing entitlement" and is the one worth recognising on sight.
    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(message) (\(status))"
    }
}
