import MeleteKit
import SwiftUI

/// Asks Melete for a playlist's songs the library doesn't have: they go to the
/// server as a playlist import, matched on MusicBrainz and asked for one by one,
/// and are followed under Requests.
struct AskForMissingButton: View {
    let name: String
    let missing: [ImportedTrack]

    @State private var isAsking = false
    @State private var asked = false
    @State private var problem: String?

    var body: some View {
        if asked {
            Label("Asked your server for them. Follow them in Requests.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Button(
                isAsking ? "Asking…" : missing.count == 1 ? "Ask Your Server for It" : "Ask Your Server for All \(missing.count)",
                systemImage: "plus.magnifyingglass"
            ) {
                Task { await ask() }
            }
            .disabled(isAsking)
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func ask() async {
        guard let client = AppSession.shared.client else { return }
        isAsking = true
        problem = nil
        defer { isAsking = false }
        do {
            _ = try await client.importPlaylist(name: name, csv: PlaylistCSV.make(missing))
            asked = true
        } catch MeleteError.http(status: 409, _, _) {
            problem = "Your server can't look music up: MusicBrainz is off in its settings."
        } catch {
            problem = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }
}
