import JellyfinKit
import PlaybackKit
import SwiftUI

/// Everything available without a connection.
///
/// Reads the download store rather than the server, so this screen is the one place
/// in the app that still works with no signal — which is the entire reason it
/// exists. Track details come from a small local index written when a download
/// finishes; without it, an offline device would know it *has* files but nothing
/// about what is in them.
struct DownloadedView: View {
    @Environment(LibraryStore.self) private var store
    @State private var downloads = DownloadStore.shared
    @State private var index = DownloadIndex.shared
    @State private var isConfirmingClear = false

    private var tracks: [JellyfinItem] {
        index.tracks.filter { downloads.state(for: $0.id).isPresent }
    }

    /// Grouped by album, in track order within each.
    ///
    /// The index sorts by title, which for a downloads screen is the wrong axis: you
    /// download albums, so a flat A–Z list interleaves them and none of them reads as
    /// the thing you actually saved.
    private var albums: [(name: String, tracks: [JellyfinItem])] {
        Dictionary(grouping: tracks) { $0.album ?? "Unknown Album" }
            .map { name, group in
                (name, group.sorted {
                    // Disc, then track — a two-disc album otherwise starts over
                    // halfway down.
                    ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0)
                        < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0)
                })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The order tapping a row plays in: the whole screen, album by album.
    private var playbackOrder: [JellyfinItem] { albums.flatMap(\.tracks) }

    var body: some View {
        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Downloaded", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download an album and it'll play without a connection — on a plane, or anywhere the signal drops.")
                }
            } else {
                List {
                    ForEach(albums, id: \.name) { album in
                        Section(album.name) {
                            ForEach(album.tracks) { track in
                                SongRow(song: track)
                                    .contentShape(.rect)
                                    .onTapGesture { play(track) }
                                    .accessibilityElement(children: .combine)
                                    .accessibilityAddTraits(.isButton)
                                    .swipeActions {
                                        Button("Remove", role: .destructive) {
                                            downloads.remove(track.id)
                                        }
                                    }
                            }
                        }
                    }

                    Section {
                        EmptyView()
                    } footer: {
                        Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s") · \(formattedSize)")
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .miniPlayerInset()
        .appBackground()
        // A large title now that this is a tab root rather than a row pushed from
        // Library — inline would leave it the only top-level screen with a small one.
        .navigationTitle("Downloads")
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove All", role: .destructive) { isConfirmingClear = true }
                }
            }
        }
        .confirmationDialog("Remove all downloads?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Remove All", role: .destructive) {
                downloads.removeAll()
                index.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The music stays on your server — you can download it again.")
        }
    }

    /// The play source stays `.unknown` — "downloaded" is a property of the file, not
    /// somewhere the listener browsed, and there is no word for it in the history.
    private func play(_ track: JellyfinItem) {
        let queue = playbackOrder
        guard let start = queue.firstIndex(where: { $0.id == track.id }) else { return }
        store.play(queue, startingAt: start)
    }

    /// Audio plus the covers and lyrics stored beside it, so the number matches what
    /// "Remove All" would actually reclaim.
    private var formattedSize: String {
        let bytes = downloads.diskUsage() + OfflineAssets.shared.diskUsage()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// What we know about downloaded tracks, kept on disk.
///
/// Separate from `DownloadStore`, which only knows that a file exists. Offline, the
/// server cannot be asked what a file contains, so the metadata has to have been
/// written down at download time or the Downloaded screen is a list of identifiers.
@MainActor
@Observable
final class DownloadIndex {
    static let shared = DownloadIndex()

    private(set) var tracks: [JellyfinItem] = []

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-tracks.json")
    }()

    private init() { load() }

    func record(_ items: [JellyfinItem]) {
        var known = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        for item in items where item.type == .audio {
            known[item.id] = item
        }
        tracks = known.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
    }

    func removeAll() {
        tracks = []
        try? FileManager.default.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        // A plain coder, not the package's Jellyfin one: this is our own round trip,
        // so the keys are already exactly what `JellyfinItem` encodes. The Jellyfin
        // decoder exists to absorb the server's PascalCase, which never applies here.
        tracks = (try? JSONDecoder().decode([JellyfinItem].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
