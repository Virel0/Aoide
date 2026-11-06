import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A form's one action, full width, with a spinner in its place while it runs:
/// the sign-in screen's button, for the Account screens.
struct BusyButton: View {
    let title: String
    let isBusy: Bool
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                Spacer()
                if isBusy {
                    ProgressView()
                } else {
                    Text(title)
                }
                Spacer()
            }
        }
        .accessibilityLabel(title)
    }
}

/// An error under the field or form it's about.
struct ErrorLabel: View {
    let message: String

    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    }
}

/// Copies a secret (a two-factor key, a password an admin gave) for pasting
/// once: kept off Universal Clipboard, and gone from the clipboard after two
/// minutes.
enum SecretPasteboard {
    static func copy(_ secret: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: secret]],
            options: [.localOnly: true, .expirationDate: Date.now.addingTimeInterval(120)]
        )
    }
}
