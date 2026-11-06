import MeleteKit
import SwiftUI

/// Two-factor sign-in: whether signing in with the password also asks for a
/// code from an authenticator app, the way to turn it on, off, or over to a
/// new device, and what has changed lately.
struct TwoFactorView: View {
    @Environment(AppSession.self) private var session
    @Environment(TwoFactorStore.self) private var store

    var body: some View {
        Form {
            if let status = store.status {
                statusSection(status)
                if status.changes.contains(where: { $0.change == .wrongSignInCode }) {
                    warningSection
                }
                if !status.changes.isEmpty {
                    Section("Recent Changes") {
                        ForEach(Array(status.changes.enumerated()), id: \.offset) { _, change in
                            TwoFactorChangeRow(change: change)
                        }
                    }
                }
            } else if let message = store.errorMessage {
                Section { ErrorLabel(message) }
            } else {
                Section { ProgressView("Asking the server…") }
            }
        }
        .navigationTitle("Two-Factor Sign-In")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.reload(session.client) }
        .refreshable { await store.reload(session.client) }
    }

    private func statusSection(_ status: TwoFactorStatus) -> some View {
        Section {
            LabeledContent("Status", value: status.on ? "On" : "Off")
            if let since = status.onSince {
                LabeledContent("On Since", value: since.formatted(date: .abbreviated, time: .shortened))
            }
            if status.on {
                NavigationLink("Turn Off") { TwoFactorOffView(thenSetUpAgain: false).environment(store) }
                NavigationLink("Reset for a New Device") { TwoFactorOffView(thenSetUpAgain: true).environment(store) }
            } else {
                NavigationLink("Turn On") { TwoFactorSetupView().environment(store) }
            }
            if let message = store.errorMessage {
                ErrorLabel(message)
            }
        } footer: {
            Text(LocalizedStringKey(status.on ? Self.onFooter : Self.offFooter))
        }
    }

    private var warningSection: some View {
        Section {
            Label {
                Text("""
                    Wrong codes were typed when signing in to this account. Whoever typed them knew your password. \
                    If it wasn't you, change your password now.
                    """)
            } icon: {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
            NavigationLink("Change Password") { ChangePasswordView() }
        }
    }

    private static let offFooter = """
        With it on, signing in with your password also asks for a six-digit code from an \
        authenticator app, such as Passwords on iPhone. Quick Connect doesn't ask for one.
        """

    private static let onFooter = """
        Signing in with your password asks for a code from your authenticator app. Reset moves it \
        to a new device or app: it turns two-factor sign-in off, then sets it up again. Without \
        the device that has your codes, an admin can turn it off on the server with \
        `melete user reset-password <name> --remove-second-factor`, which sets a new password too.
        """
}

/// One change to two-factor sign-in, in plain words.
private struct TwoFactorChangeRow: View {
    let change: TwoFactorChange

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(change.change == .wrongSignInCode ? .orange : .secondary)
            }
            Text(change.at.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch (change.change, change.madeFrom) {
        case (.wrongSignInCode, _):
            change.count == 1 ? "A wrong code was typed at sign-in" : "\(change.count) wrong codes were typed at sign-in"
        case (.turnedOn, .server): "Turned on on the server"
        case (.turnedOn, _): "Turned on from your account"
        case (.turnedOff, .server): "Turned off on the server by an admin"
        case (.turnedOff, _): "Turned off from your account"
        }
    }

    private var symbol: String {
        switch change.change {
        case .wrongSignInCode: "exclamationmark.triangle.fill"
        case .turnedOn: "lock.fill"
        case .turnedOff: "lock.open"
        }
    }
}
