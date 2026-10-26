import Intents
import SwiftUI
import os

/// Siri permission.
///
/// Declaring the intents and handling them is not enough: until the app asks, iOS
/// has no permission to route anything to it, and Siri answers spoken requests with
/// "Aoide hasn't been set up" or "I can't search for music on Aoide" — which reads
/// like the feature is missing rather than un-permitted.
@MainActor
@Observable
final class SiriAuthorization {
    static let shared = SiriAuthorization()

    private(set) var status: INSiriAuthorizationStatus = INPreferences.siriAuthorizationStatus()
    private let log = Logger(subsystem: AppIdentity.bundle, category: "siri")

    private init() {}

    var isAuthorized: Bool { status == .authorized }

    var summary: String {
        switch status {
        case .authorized: "On"
        case .denied: "Off — turn it on in Settings"
        case .restricted: "Not available on this device"
        case .notDetermined: "Not set up yet"
        @unknown default: "Unknown"
        }
    }

    /// Asked once the user is signed in, because a Siri prompt on the login screen
    /// is asking for something they cannot yet use.
    func requestIfNeeded() {
        guard status == .notDetermined else { return }
        INPreferences.requestSiriAuthorization { [weak self] newStatus in
            Task { @MainActor in
                self?.status = newStatus
                self?.log.info("Siri authorisation: \(newStatus.rawValue, privacy: .public)")
            }
        }
    }

    /// Re-read on foreground: it can be changed in Settings behind our back.
    func refresh() {
        status = INPreferences.siriAuthorizationStatus()
    }
}
