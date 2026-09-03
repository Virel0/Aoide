import JellyfinKit
import SwiftUI

struct LoginView: View {
    @State private var session = AppSession.shared

    /// Pre-filled with the server this device last signed in to, or the one the
    /// build was configured for (`AOIDE_DEFAULT_SERVER` in Config/Local.xcconfig),
    /// so nobody types an address twice. Nothing is baked into the source: a public
    /// checkout offers an empty field. Still editable.
    @State private var serverAddress = Self.suggestedServerAddress
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: Field?

    private enum Field { case server, username, password }

    private static var suggestedServerAddress: String {
        if let last = UserDefaults.standard.string(forKey: AppSession.lastServerAddressKey), !last.isEmpty {
            return last
        }
        let configured = Bundle.main.object(forInfoDictionaryKey: "AoideDefaultServer") as? String
        return configured?.trimmingCharacters(in: .whitespaces) ?? ""
    }

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
                    Text("The address of your Jellyfin server. Home addresses like `192.168.1.10:8096` connect over plain HTTP; anything else uses HTTPS. Type a full address to override.")
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
            .navigationTitle("Aoide")
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
