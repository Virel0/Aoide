import MeleteKit
import SwiftUI

/// Turning two-factor sign-in off, with the password and a current code; or,
/// as Reset, turning it off and straight away setting it up again for a new
/// device or app.
struct TwoFactorOffView: View {
    let thenSetUpAgain: Bool

    @Environment(AppSession.self) private var session
    @Environment(TwoFactorStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var problem: (field: MeleteSecret?, message: String)?
    /// Reset's new secret, once two-factor sign-in is off.
    @State private var nextSetup: TwoFactorSetup?
    @FocusState private var focused: MeleteSecret?

    var body: some View {
        if let nextSetup {
            TwoFactorSetupView(startingWith: nextSetup)
                .onDisappear { self.nextSetup = nil }
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.next)
                    .onSubmit { focused = .code }
                problemRow(for: .password)
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused, equals: .code)
                problemRow(for: .code)
            } footer: {
                Text(thenSetUpAgain ? Self.resetFooter : Self.offFooter)
            }

            Section {
                BusyButton(
                    title: thenSetUpAgain ? "Reset Two-Factor Sign-In" : "Turn Off Two-Factor Sign-In",
                    isBusy: isWorking,
                    role: .destructive,
                    action: turnOff
                )
                    .disabled(isWorking || password.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty)
                if let problem, problem.field == nil {
                    ErrorLabel(problem.message)
                }
            } footer: {
                Text(LocalizedStringKey(Self.lostDevice))
            }
        }
        .navigationTitle(thenSetUpAgain ? "Reset Two-Factor" : "Turn Off Two-Factor")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: clear)
    }

    @ViewBuilder
    private func problemRow(for field: MeleteSecret) -> some View {
        if let problem, problem.field == field {
            ErrorLabel(problem.message)
                .font(.footnote)
        }
    }

    private func turnOff() {
        guard !isWorking, let client = session.client else { return }
        isWorking = true
        problem = nil
        let typed = password
        Task {
            defer { isWorking = false }
            do {
                try await client.turnOffTwoFactor(password: typed, code: code)
            } catch is CancellationError {
                return
            } catch {
                show(error)
                return
            }
            code = ""
            await store.reload(client)
            guard thenSetUpAgain else {
                clear()
                dismiss()
                return
            }
            await setUpAgain(client, password: typed)
        }
    }

    /// Reset's second half: a new secret, with the password just typed.
    private func setUpAgain(_ client: MeleteClient, password typed: String) async {
        defer { clear() }
        do {
            nextSetup = try await client.startTwoFactor(password: typed)
        } catch {
            let reason = AccountMessage.words(for: error, while: .startingTwoFactor)
            problem = (nil, "Two-factor sign-in is off. Setting it up again didn't start: \(reason) Turn it on from Two-Factor Sign-In.")
        }
    }

    private func show(_ error: any Error) {
        let field: MeleteSecret? = if case MeleteError.wrong(let secret) = error { secret } else { nil }
        if field == .code { code = "" }
        problem = (field, AccountMessage.words(for: error, while: .turningOffTwoFactor))
        focused = field
    }

    private func clear() {
        password = ""
        code = ""
    }

    private static let offFooter = "Your Melete password, and the code your authenticator app shows now. Nothing is signed out."
    private static let resetFooter = """
        Your Melete password, and the code your authenticator app shows now. Two-factor sign-in \
        is turned off, then a new secret is shown for your new device or app. Until you confirm \
        it, signing in asks only for your password.
        """
    private static let lostDevice = """
        Lost the device with your codes? An admin can turn two-factor sign-in off on the server \
        with `melete user reset-password <name> --remove-second-factor`, which sets a new \
        password too.
        """
}
