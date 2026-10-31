import MeleteKit
import SwiftUI

/// Listen Together, from Now Playing: start a session with this queue or join
/// one by its code; once in one, its code, who's in it, and Leave (and End for
/// Everyone for whoever started it).
struct ListenTogetherSheet: View {
    @State private var together = ListenTogetherCoordinator.shared
    @FocusState private var isTypingCode: Bool

    var body: some View {
        NavigationStack {
            Form {
                if let session = together.session {
                    inSession(session)
                } else {
                    outside
                }
                if let problem = together.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Listen Together")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(together.isBusy)
        }
    }

    @ViewBuilder
    private var outside: some View {
        Section {
            Button("Start with This Queue") {
                Task { await together.start() }
            }
        } footer: {
            Text("Everyone who joins plays along, each device streaming for itself. They can be on any Aoide, signed in to this server.")
        }

        Section("Join") {
            TextField("Code", text: $together.code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($isTypingCode)
                .submitLabel(.join)
                .onSubmit { Task { await together.join() } }
            Button("Join") {
                isTypingCode = false
                Task { await together.join() }
            }
            .disabled(together.code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func inSession(_ session: ListenSession) -> some View {
        let me = session.members.first { $0.you }
        Section {
            Text(session.code)
                .font(.system(.largeTitle, design: .monospaced).weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityLabel("Code \(session.code.map(String.init).joined(separator: " "))")
        } header: {
            Text("Listening Together")
        } footer: {
            Text("Others join with this code, from Listen Together on their own device.")
        }

        Section("Who's Here") {
            ForEach(Array(session.members.enumerated()), id: \.offset) { _, member in
                LabeledContent(member.username, value: member.you ? "\(member.device) (this device)" : member.device)
            }
        }

        Section {
            Button("Leave") {
                Task { await together.leave(forEveryone: false) }
            }
            if me?.username == session.host {
                Button("End for Everyone", role: .destructive) {
                    Task { await together.leave(forEveryone: true) }
                }
            }
        }
    }
}
