import CurationKit
import MeleteKit
import SwiftUI

/// A set of songs on their way into a playlist.
///
/// `[MusicItem]` is not `Identifiable`, and `.sheet(item:)` is the presentation that
/// cannot show the wrong contents: `isPresented` plus a separate array is two pieces of
/// state that can disagree for one frame, which is exactly long enough to add the
/// previous song to a playlist.
struct TrackSelection: Identifiable {
    let id = UUID()
    let tracks: [MusicItem]

    init(_ tracks: [MusicItem]) {
        self.tracks = tracks
    }
}

/// Pick a playlist, or make one on the spot.
struct AddToPlaylistSheet: View {
    let selection: TrackSelection

    @Environment(LocalPlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var newName = ""
    @State private var errorMessage: String?

    /// Smart playlists are absent rather than shown-and-disabled. They choose their own
    /// songs — there is no list to add to — and a greyed row invites the listener to work
    /// out why on their own.
    private var targets: [Playlist] { playlists.playlists.filter { !$0.isSmart } }

    private var title: String {
        selection.tracks.count == 1
            ? selection.tracks[0].name
            : "\(selection.tracks.count) songs"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        isCreating = true
                    } label: {
                        Label("New Playlist", systemImage: "plus.circle.fill")
                    }
                    .disabled(!playlists.isAvailable)
                }

                Section {
                    if !playlists.isAvailable {
                        Text(LocalPlaylistStore.unavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if targets.isEmpty {
                        Text("You don't have a playlist yet. Make one above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(targets, id: \.id) { list in
                            Button {
                                Task { await add(to: list) }
                            } label: {
                                HStack(spacing: 12) {
                                    PlaylistArtwork(playlist: list, albumIds: playlists.coverAlbums[list.id] ?? [])
                                        .frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        // `Color.primary` rather than `.primary`: the
                                        // hierarchical style resolves against the
                                        // button's tint and would turn every row violet.
                                        Text(list.name)
                                            .foregroundStyle(Color.primary)
                                        if let count = playlists.trackCounts[list.id] {
                                            Text("\(count) song\(count == 1 ? "" : "s")")
                                                .font(.caption)
                                                .foregroundStyle(Color.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Add “\(title)” to")
                } footer: {
                    Text("These are the playlists kept on your device.")
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await playlists.reload() }
            .alert("New Playlist", isPresented: $isCreating) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        // Created and filled in one gesture: coming here from a song, the
                        // only reason to make a playlist is to put that song in it, and
                        // leaving it empty would make the next step a mystery.
                        guard let created = await playlists.createPlaylist(name: name) else { return }
                        await add(to: created)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "Couldn't add those songs",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func add(to list: Playlist) async {
        let added = await playlists.add(selection.tracks, to: list)
        guard added > 0 else {
            errorMessage = playlists.lastErrorMessage ?? "Nothing was added."
            playlists.lastErrorMessage = nil
            return
        }
        dismiss()
    }
}
