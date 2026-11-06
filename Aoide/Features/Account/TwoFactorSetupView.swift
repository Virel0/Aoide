import MeleteKit
import SwiftUI

/// Turning two-factor sign-in on: the password, then the new secret for an
/// authenticator app (as a link, a QR code and text), then a first code.
///
/// The secret is the account's second key. It lives in this screen's state
/// only, is never logged or kept, and is cleared when the screen closes.
struct TwoFactorSetupView: View {
    @Environment(AppSession.self) private var session
    @Environment(TwoFactorStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var password = ""
    @State private var code = ""
    @State private var setup: TwoFactorSetup?
    @State private var isOn = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    /// `setup` is a secret already started, when Reset has just turned
    /// two-factor sign-in off and asked for a new one.
    init(startingWith setup: TwoFactorSetup? = nil) {
        _setup = State(initialValue: setup)
    }

    var body: some View {
        Form {
            if isOn {
                doneSection
            } else if let setup {
                TwoFactorSecretSection(setup: setup, open: open)
                codeSection
            } else {
                passwordSection
            }
        }
        .navigationTitle("Turn On Two-Factor")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: forget)
    }

    private var passwordSection: some View {
        Section {
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused)
                .submitLabel(.next)
                .onSubmit(start)
            errorRow
            BusyButton(title: "Continue", isBusy: isWorking, action: start)
                .disabled(isWorking || password.isEmpty)
        } footer: {
            Text("""
                Your Melete password, to show the secret for your authenticator app. Nothing changes until you \
                confirm with a first code.
                """)
        }
    }

    private var codeSection: some View {
        Section {
            TextField("123456", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced))
                .focused($focused)
                .submitLabel(.go)
                .onSubmit(confirm)
            errorRow
            BusyButton(title: "Turn On", isBusy: isWorking, action: confirm)
                .disabled(isWorking || code.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Code")
        } footer: {
            Text("The six-digit code your authenticator app now shows for Melete. It changes every 30 seconds.")
        }
    }

    /// What went wrong, under the field it's about.
    @ViewBuilder
    private var errorRow: some View {
        if let errorMessage {
            ErrorLabel(errorMessage)
                .font(.footnote)
        }
    }

    private var doneSection: some View {
        Section {
            Label("Two-factor sign-in is on", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
            Text("Signing in with your password now asks for a code from your authenticator app. Devices already signed in stay signed in.")
                .font(.subheadline)
            Button("Done") { dismiss() }
        }
    }

    private func open(_ setup: TwoFactorSetup) {
        guard let url = URL(string: setup.uri) else { return }
        openURL(url) { accepted in
            if !accepted {
                errorMessage = "No app on this iPhone takes the setup link. Scan the QR code from another device, or type the secret."
            }
        }
    }

    private func start() {
        guard !isWorking, !password.isEmpty, let client = session.client else { return }
        run(.startingTwoFactor) {
            setup = try await client.startTwoFactor(password: password)
            password = ""
            focused = true
        }
    }

    private func confirm() {
        guard !isWorking, let client = session.client else { return }
        run(.confirmingTwoFactor) {
            do {
                try await client.confirmTwoFactor(code: code)
            } catch {
                // Nothing is waiting for this code: back to the password for a
                // new secret.
                if case MeleteError.http(status: 409, _, _) = error { forget() }
                throw error
            }
            forget()
            isOn = true
            await store.reload(client)
        }
    }

    private func run(_ action: AccountMessage.Action, _ body: @escaping () async throws -> Void) {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await body()
            } catch is CancellationError {
                return
            } catch {
                if case MeleteError.wrong(.code) = error { code = "" }
                errorMessage = AccountMessage.words(for: error, while: action)
            }
        }
    }

    /// Drops the secret and whatever was typed.
    private func forget() {
        setup = nil
        password = ""
        code = ""
    }
}

/// The new secret, three ways: a link that hands it to Passwords or an
/// authenticator app on this iPhone, a QR code for another device, and the
/// text to type in.
private struct TwoFactorSecretSection: View {
    let setup: TwoFactorSetup
    let open: (TwoFactorSetup) -> Void

    var body: some View {
        Section {
            Button("Add to Passwords or an Authenticator App", systemImage: "key.fill") { open(setup) }
            QRCodeView(text: setup.uri)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR code of the setup link, for an authenticator app on another device")
            VStack(alignment: .leading, spacing: 6) {
                Text("Secret")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.grouped(setup.secret))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Copy Secret", systemImage: "doc.on.doc") { SecretPasteboard.copy(setup.secret) }
        } header: {
            Text("Secret")
        } footer: {
            Text("""
                Add it to an authenticator app: tap the button on this iPhone, scan the code from another \
                device, or type the secret. Keep it to yourself: with it and your password, anyone can sign in.
                """)
        }
    }

    /// In fours, as authenticator apps show and take it.
    static func grouped(_ secret: String) -> String {
        stride(from: 0, to: secret.count, by: 4).map { start in
            let from = secret.index(secret.startIndex, offsetBy: start)
            let to = secret.index(from, offsetBy: 4, limitedBy: secret.endIndex) ?? secret.endIndex
            return String(secret[from..<to])
        }.joined(separator: " ")
    }
}
