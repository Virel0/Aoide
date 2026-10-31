import MeleteKit
import SwiftUI

/// Asking for what the library doesn't have, at the foot of Search's results: the
/// words looked up on MusicBrainz through Melete (albums, artists and songs),
/// each marked in the library, wanted or asked for already, else with Ask.
///
/// Looked up only when asked: MusicBrainz is slow and the server paces it, and a
/// lookup at every pause in typing would be both. Give it `.id(term)` so a new
/// term starts afresh.
struct AskForItSection: View {
    let term: String

    @State private var found: [RequestCandidate]?
    @State private var isLooking = false
    @State private var problem: String?
    /// What asking said, by place in `found`: where it stands now, or why not.
    @State private var answers: [Int: String] = [:]
    @State private var asking: Int?

    var body: some View {
        Section {
            if let found {
                if found.isEmpty {
                    Text("MusicBrainz has nothing by that name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(found.enumerated()), id: \.offset) { place, candidate in
                    row(place, candidate)
                }
            } else if isLooking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking it up on MusicBrainz…").foregroundStyle(.secondary)
                }
            } else {
                Button("Not in your library? Look it up to ask for it", systemImage: "plus.magnifyingglass") {
                    Task { await lookUp() }
                }
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Ask for It")
        }
    }

    private func row(_ place: Int, _ candidate: RequestCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).lineLimit(1)
                Text(candidate.about)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let answer = answers[place] {
                note(answer)
            } else if candidate.inLibrary {
                note("In your library")
            } else if candidate.wanted {
                note("Wanted")
            } else if candidate.requested != nil {
                note("Asked for")
            } else {
                Button(asking == place ? "Asking…" : "Ask") {
                    Task { await ask(place, candidate) }
                }
                .buttonStyle(.bordered)
                .disabled(asking != nil)
            }
        }
    }

    private func note(_ words: String) -> some View {
        Text(words)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
    }

    private func lookUp() async {
        guard let client = AppSession.shared.client else { return }
        isLooking = true
        problem = nil
        defer { isLooking = false }
        do {
            async let albums = client.requestSearch(.album, words: term)
            async let artists = client.requestSearch(.artist, words: term)
            async let songs = client.requestSearch(.song, words: term)
            found = try await albums + artists + songs
        } catch MeleteError.http(status: 409, _, _) {
            problem = "Your server can't look music up: MusicBrainz is off in its settings."
        } catch {
            problem = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func ask(_ place: Int, _ candidate: RequestCandidate) async {
        guard let client = AppSession.shared.client else { return }
        asking = place
        defer { asking = nil }
        do {
            answers[place] = try await client.askFor(candidate).standing
        } catch MeleteError.http(status: 409, _, let detail) {
            answers[place] = detail ?? "Asked for already"
        } catch {
            answers[place] = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }
}
