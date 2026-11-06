import MeleteKit
import SwiftUI

/// Changing your own password, which signs out every other device and API key
/// on the account. The passwords live in this screen's state only: never
/// logged, never kept, cleared once it's done or the screen closes.
struct ChangePasswordView: View {
    @Environment(AppSession.self) private var session

    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var isWorking = false
    @State private var problem: Problem?
    @State private var isDone = false
    @FocusState private var focused: Field?

    private enum Field { case current, new, repeated }

    private struct Problem {
        let field: Field?
        let message: String
    }

    private static let lengths = 8...1024

    var body: some View {
        Form {
            if isDone {
                Section {
                    Label("Password changed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("""
                        Your other devices and apps, and any API keys, are signed out. Sign them in again with the new \
                        password. This iPhone stays signed in.
                        """)
                        .font(.subheadline)
                }
            }

            Section {
                SecureField("Current Password", text: $current)
                    .textContentType(.password)
                    .focused($focused, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focused = .new }
                problemRow(for: .current)
            } footer: {
                Text("""
                    Changing your password signs out every other device and app on this account, and any API keys. \
                    This iPhone stays signed in.
                    """)
            }

            Section {
                SecureField("New Password", text: $new)
                    .textContentType(.newPassword)
                    .focused($focused, equals: .new)
                    .submitLabel(.next)
                    .onSubmit { focused = .repeated }
                problemRow(for: .new)
                SecureField("New Password Again", text: $repeated)
                    .textContentType(.newPassword)
                    .focused($focused, equals: .repeated)
                    .submitLabel(.go)
                    .onSubmit(change)
                problemRow(for: .repeated)
            } footer: {
                Text("8 to 1,024 characters.")
            }

            Section {
                BusyButton(title: "Change Password", isBusy: isWorking, action: change)
                    .disabled(isWorking || current.isEmpty || new.isEmpty || repeated.isEmpty)
                if let problem, problem.field == nil {
                    ErrorLabel(problem.message)
                }
            }
        }
        .navigationTitle("Change Password")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: clear)
    }

    @ViewBuilder
    private func problemRow(for field: Field) -> some View {
        if let problem, problem.field == field {
            ErrorLabel(problem.message)
                .font(.footnote)
        }
    }

    /// What's wrong before anything is sent, if anything.
    private var localProblem: Problem? {
        if !Self.lengths.contains(new.count) {
            return Problem(field: .new, message: "The new password needs 8 to 1,024 characters.")
        }
        if new != repeated {
            return Problem(field: .repeated, message: "The two new passwords aren't the same. Type it again.")
        }
        return nil
    }

    private func change() {
        guard !isWorking, let client = session.client else { return }
        isDone = false
        if let localProblem {
            problem = localProblem
            focused = localProblem.field
            return
        }
        problem = nil
        isWorking = true
        let (old, chosen) = (current, new)
        Task {
            defer { isWorking = false }
            do {
                try await client.changePassword(current: old, new: chosen)
                clear()
                isDone = true
            } catch is CancellationError {
                return
            } catch {
                let field: Field? = switch error {
                case MeleteError.wrong(.password): .current
                case MeleteError.http(status: 400, _, _): .new
                default: nil
                }
                problem = Problem(field: field, message: AccountMessage.words(for: error, while: .changingPassword))
                focused = field
            }
        }
    }

    private func clear() {
        current = ""
        new = ""
        repeated = ""
        focused = nil
    }
}
