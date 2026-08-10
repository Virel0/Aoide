import CurationKit
import JellyfinKit
import SwiftUI

/// Describe a mood, hear a mix.
///
/// Nothing is kept unless you say so. A mix is a queue you can walk away from, and
/// "Save" turns it into a smart playlist holding the *rules* rather than the tracks —
/// so it stays fresh, re-runs as listening changes, and travels to the desktop app,
/// which writes and reads the same rule set.
struct MixView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(LocalPlaylistStore.self) private var playlists
    @Environment(AppSession.self) private var session

    @State private var composer: MixComposer?
    @State private var description = ""
    @State private var rules: SmartRules?
    @State private var tracks: [JellyfinItem] = []
    @State private var isBuilding = false
    @State private var message: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.shelf) {
                    prompt

                    if let message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .pageMargin()
                    }

                    if !tracks.isEmpty {
                        actions
                        trackList
                    }
                }
                .padding(.vertical, 12)
            }
            .miniPlayerInset()
            .appBackground()
            .navigationTitle("Mixes")
            .task {
                guard composer == nil, let client = session.client else { return }
                composer = MixComposer(client: client)
            }
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Deliberately a sentence rather than a search field: the difference
            // between this and search is that a description is meant to be vague.
            TextField("Something calm I haven't heard in months", text: $description, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isTyping)
                .submitLabel(.go)
                .onSubmit(build)

            Divider()

            HStack {
                if case .unavailable(let why) = composer?.readiness {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button(action: build) {
                        if isBuilding {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Make a mix", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBuilding || description.trimmed.isEmpty)
                }
                Spacer()
            }
        }
        .pageMargin()
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                library.play(tracks, from: .smart)
            } label: {
                Label("Play \(tracks.count)", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button("Save", action: save)
                .buttonStyle(.bordered)

            Button("Discard") {
                tracks = []
                rules = nil
                message = nil
            }
            .buttonStyle(.borderless)
        }
        .pageMargin()
    }

    private var trackList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                SongRow(song: track)
                    .contentShape(.rect)
                    .onTapGesture { library.play(tracks, startingAt: index, from: .smart) }
                    .padding(.vertical, 4)
            }
        }
        .pageMargin()
    }

    private func build() {
        guard let composer, !description.trimmed.isEmpty else { return }

        isTyping = false
        isBuilding = true
        message = nil
        tracks = []

        Task {
            defer { isBuilding = false }

            guard let composed = await composer.compose(description) else {
                message = "Couldn't turn that into a mix. Try describing it another way."
                return
            }
            rules = composed

            guard let store = CurationDatabase.shared else {
                message = "This device has no library store yet."
                return
            }

            // The rules are evaluated locally, against the track cache and the play
            // history. No network, which is the whole reason a mix works on a plane.
            let ids: [String]
            do {
                ids = try await Task.detached { try store.evaluate(composed) }.value
            } catch {
                message = "Those rules couldn't be evaluated."
                return
            }

            guard !ids.isEmpty else {
                message = "Nothing in your library matched that."
                return
            }

            // Capped before asking the server: a rule set can legitimately match the
            // whole library — "never played" on a fresh install is exactly that — and
            // a mix nobody will reach the end of is not worth the round trips.
            guard let client = session.client else { return }
            let wanted = Array(ids.prefix(200))

            do {
                let items = try await client.items(ids: wanted)
                let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                // Kept in the rules' own order rather than the server's.
                tracks = wanted.compactMap { byId[$0] }
            } catch {
                message = "Couldn't reach your server to load the tracks."
            }
        }
    }

    private func save() {
        guard let rules else { return }
        let name = String(description.trimmed.prefix(60))

        Task {
            // Saved as rules, not as the tracks it happened to pick today. A mix
            // frozen to a track list stops being the thing that was described.
            if await playlists.createSmartPlaylist(name: name, rules: rules) != nil {
                message = "Saved. It re-runs every time you open it."
            } else {
                message = "Couldn't save that mix."
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
