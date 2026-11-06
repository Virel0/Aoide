import MeleteKit
import SwiftUI

/// Settings → Account: your profile picture, your password, two-factor
/// sign-in, and for an admin, other users' passwords. Everything here is your
/// Melete account's, so it's the same in every app signed in to it.
///
/// A pushed screen here doesn't see an observable set on the screen that
/// pushed it (a missing one traps), so each link hands its store on itself.
struct AccountView: View {
    @Environment(AppSession.self) private var session
    @Environment(AccountStore.self) private var account
    @State private var twoFactor = TwoFactorStore()

    var body: some View {
        Form {
            ProfilePictureSection()

            Section {
                NavigationLink("Change Password") { ChangePasswordView() }
                NavigationLink {
                    TwoFactorView().environment(twoFactor)
                } label: {
                    LabeledContent("Two-Factor Sign-In", value: twoFactorSummary)
                }
            } header: {
                Text("Sign-In")
            }

            if account.me?.isAdmin == true {
                Section {
                    NavigationLink("Users' Passwords") { UserPasswordsView() }
                } header: {
                    Text("Server")
                } footer: {
                    Text("As an admin of this server, you can give someone a new password when they've lost theirs.")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .environment(twoFactor)
        .task {
            await account.refresh(session.client)
            await twoFactor.reload(session.client)
        }
    }

    private var twoFactorSummary: String {
        guard let status = twoFactor.status else { return "" }
        return status.on ? "On" : "Off"
    }
}
