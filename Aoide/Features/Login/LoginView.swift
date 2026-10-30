import MeleteKit
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
    /// Quick Connect's code while it waits to be approved.
    @State private var quickCode: String?
    @State private var quickConnect: Task<Void, Never>?

    @FocusState private var focusedField: Field?

    private enum Field { case server, username, password }

    /// How often a Quick Connect code is asked about while it waits.
    private static let pollEvery: Duration = .seconds(3)

    private static var suggestedServerAddress: String {
        if let last = UserDefaults.standard.string(forKey: AppSession.lastServerAddressKey), !last.isEmpty {
            return last
        }
        let configured = Bundle.main.object(forInfoDictionaryKey: "AoideDefaultServer") as? String
        return configured?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private var hasServer: Bool { !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty }

    private var canSubmit: Bool {
        hasServer && !username.trimmingCharacters(in: .whitespaces).isEmpty && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("melete.local:8100", text: $serverAddress)
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
                    Text("""
                        The address of your Melete server. Home addresses like `192.168.1.10:8100` connect \
                        over plain HTTP; anything else uses HTTPS. Type a full address to override.
                        """)
                }

                if let quickCode {
                    quickConnectSection(quickCode)
                } else {
                    accountSection
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Aoide")
            .disabled(isConnecting && quickCode == nil)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
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

            Button("Sign In with Quick Connect", action: startQuickConnect)
                .frame(maxWidth: .infinity)
                .disabled(!hasServer || isConnecting)
        } footer: {
            Text("Quick Connect signs in without a password: approve the code it shows in Melete's web UI, on a device that's signed in.")
        }
    }

    private func quickConnectSection(_ code: String) -> some View {
        Section {
            Text(code)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            Button("Cancel", role: .cancel, action: cancelQuickConnect)
                .frame(maxWidth: .infinity)
        } header: {
            Text("Quick Connect")
        } footer: {
            Text("""
                In Melete's web UI, open Quick Connect and enter this code. It works for five minutes; \
                this screen signs in once it's approved.
                """)
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
                errorMessage = Self.words(for: error)
            }
            isConnecting = false
        }
    }

    private func startQuickConnect() {
        focusedField = nil
        isConnecting = true
        errorMessage = nil
        let address = serverAddress
        quickConnect = Task {
            defer {
                isConnecting = false
                quickCode = nil
            }
            do {
                let (client, code) = try await session.startQuickConnect(serverAddress: address)
                quickCode = code.code
                while !Task.isCancelled {
                    try await Task.sleep(for: Self.pollEvery)
                    if try await session.pollQuickConnect(client: client, secret: code.secret) { return }
                }
            } catch is CancellationError {
                return
            } catch MeleteError.notFound {
                errorMessage = "The code ran out before it was approved. Start again for a new one."
            } catch {
                errorMessage = Self.words(for: error)
            }
        }
    }

    private func cancelQuickConnect() {
        quickConnect?.cancel()
        quickConnect = nil
    }

    /// `MeleteError` carries messages written for humans; anything else gets the
    /// system description rather than a raw enum dump.
    private static func words(for error: any Error) -> String {
        if case MeleteError.http(status: 429, _, _) = error {
            return "Too many tries with this username. Wait 15 minutes, then try again."
        }
        return (error as? MeleteError)?.errorDescription ?? error.localizedDescription
    }
}
