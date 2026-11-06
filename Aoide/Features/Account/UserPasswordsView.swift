import MeleteKit
import SwiftUI

/// For an admin: the server's other users, and a new password for one who
/// lost theirs. The server makes the password up and shows it once; it is
/// shown here once too, and gone when the sheet closes.
struct UserPasswordsView: View {
    @Environment(AppSession.self) private var session

    @State private var users: [MeleteUser]?
    @State private var errorMessage: String?
    @State private var confirming: MeleteUser?
    @State private var working: String?
    @State private var given: GivenPassword?

    private var ownId: String? { session.client?.credentials?.userId }

    var body: some View {
        List {
            if let users {
                Section {
                    ForEach(users.filter { $0.id != ownId }) { user in
                        row(user)
                    }
                } footer: {
                    Text("A new password signs them out of every device and app, and any API keys. Change your own under Change Password.")
                }
            } else if errorMessage == nil {
                ProgressView("Loading users…")
            }
            if let errorMessage {
                Section { ErrorLabel(errorMessage) }
            }
        }
        .navigationTitle("Users' Passwords")
        .navigationBarTitleDisplayMode(.inline)
        .task { if users == nil { await load() } }
        .confirmationDialog(
            "Give \(confirming?.name ?? "") a new password?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { user in
            Button("Give a New Password", role: .destructive) { give(user) }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text("\(user.name)'s password stops working, and they're signed out of every device and app. You'll see the new one once, to pass on to them.")
        }
        .sheet(item: Binding(get: { given.map(Shown.init) }, set: { if $0 == nil { given = nil } })) { shown in
            GivenPasswordSheet(given: shown.given) { given = nil }
        }
    }

    private func row(_ user: MeleteUser) -> some View {
        HStack(spacing: 10) {
            AvatarView(name: user.name, url: session.client?.avatarURL(user.avatarUrl))
            VStack(alignment: .leading) {
                Text(user.name)
                if user.isAdmin {
                    Text("Admin").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if working == user.id {
                ProgressView()
            } else {
                Button("Give a New Password") { confirming = user }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .disabled(working != nil)
                    .accessibilityLabel("Give \(user.name) a new password")
            }
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        do {
            users = try await client.users().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = AccountMessage.words(for: error, while: .loadingUsers)
        }
    }

    private func give(_ user: MeleteUser) {
        guard let client = session.client else { return }
        working = user.id
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                given = try await client.giveNewPassword(toUser: user.id)
            } catch {
                errorMessage = AccountMessage.words(for: error, while: .givingPassword)
            }
        }
    }

    /// The sheet's item: one per password given.
    private struct Shown: Identifiable {
        let given: GivenPassword
        var id: String { given.username }
    }
}

/// The password an admin just gave, shown once to pass on.
private struct GivenPasswordSheet: View {
    let given: GivenPassword
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(given.password)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy Password", systemImage: "doc.on.doc") { SecretPasteboard.copy(given.password) }
                } header: {
                    Text("New Password for \(given.username)")
                } footer: {
                    Text("""
                        Pass it on privately: in person, or in a message only they can read. Aoide doesn't keep it, so \
                        once this closes it's gone. They can change it after signing in.
                        """)
                }
            }
            .navigationTitle("New Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        .interactiveDismissDisabled()
    }
}
