import JellyfinKit
import SwiftUI

struct LoginView: View {
    @State private var session = AppSession.shared

    /// Pre-filled: this build is for one server and a handful of people, so making
    /// everyone type an address serves nobody. Still editable.
    @State private var serverAddress = "https://music.example.net"
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field { case server, username, password }

    private var canSubmit: Bool {
        !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("jellyfin.local:8096", text: $serverAddress)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .username }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your Jellyfin server. `https://` is assumed only if you type it — a bare address connects over plain HTTP, which is how most home servers run.")
                }

                Section("Account") {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if canSubmit { connect() } }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: connect) {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Connect")
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("JellyMusic")
            .disabled(isConnecting)
        }
    }

    private func connect() {
        focusedField = nil
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await session.signIn(
                    serverAddress: serverAddress,
                    username: username,
                    password: password
                )
            } catch {
                // `JellyfinError` carries messages written for humans; anything else
                // gets the system description rather than a raw enum dump.
                errorMessage = (error as? JellyfinError)?.errorDescription
                    ?? error.localizedDescription
            }
            isConnecting = false
        }
    }
}
