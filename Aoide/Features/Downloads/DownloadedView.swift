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
///
/// Shown the way it was downloaded: a playlist is one row, an album is one row, and
/// only a song fetched on its own is listed as a song. The alternative — every file
/// flat on one screen — made a downloaded playlist indistinguishable from sixty
/// unrelated tracks.
struct DownloadedView: View {
    @Environment(LibraryStore.self) private var store
    @State private var downloads = DownloadStore.shared
    @State private var index = DownloadIndex.shared
    @State private var isConfirmingClear = false

    private var tracks: [JellyfinItem] {
        index.tracks.filter { downloads.state(for: $0.id).isPresent }
    }

    private var presentIds: Set<String> { Set(tracks.map(\.id)) }

    /// Collections with at least one file still on disk, by kind.
    private func collections(of kind: DownloadedCollection.Kind) -> [DownloadedCollection] {
        index.collections
            .filter { $0.kind == kind && $0.trackIds.contains(where: presentIds.contains) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Songs downloaded on their own — in no album or playlist that was downloaded whole.
    private var looseTracks: [JellyfinItem] {
        let filed = Set(index.collections.flatMap(\.trackIds))
        return tracks
            .filter { !filed.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        let playlists = collections(of: .playlist)
        let albums = collections(of: .album)
        let songs = looseTracks

        Group {
            if tracks.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Downloaded", systemImage: "arrow.down.circle")
                } description: {
                    Text("Download an album and it'll play without a connection — on a plane, or anywhere the signal drops.")
                }
            } else {
                List {
                    damagedBanner
                    if !playlists.isEmpty {
                        Section("Playlists") {
                            ForEach(playlists) { collectionRow($0) }
                        }
                    }
                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(albums) { collectionRow($0) }
                        }
                    }
                    if !songs.isEmpty {
                        Section("Songs") {
                            ForEach(songs) { track in
                                SongRow(song: track)
                                    .contentShape(.rect)
                                    .onTapGesture { play(track, in: songs) }
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
        .navigationDestination(for: DownloadedCollection.self) { collection in
            DownloadedCollectionView(collection: collection)
        }
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
        // A collection whose every file has since been removed one by one is not
        // worth remembering; pruned here so the record cannot come back as an
        // empty row after the next download.
        .task { index.prune(keeping: presentIds) }
    }

    /// Files the player refused, found by the launch check. Named rather than
    /// silently dropped: a download that vanishes is a mystery, one that says why
    /// it went and offers to come back is a fixed problem.
    @ViewBuilder
    private var damagedBanner: some View {
        let damaged = index.tracks.filter { downloads.damaged.contains($0.id) }
        if !damaged.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "\(damaged.count) download\(damaged.count == 1 ? "" : "s") couldn't be played and \(damaged.count == 1 ? "was" : "were") removed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    if let problem = downloads.lastCheck?.firstProblem {
                        Text(problem)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Button("Download Again", systemImage: "arrow.down.circle") {
                        store.download(damaged)
                    }
                    .buttonStyle(.bordered)
                    .clipShape(.capsule)
                }
                .listRowSeparator(.hidden)
            }
        }
    }

    private func collectionRow(_ collection: DownloadedCollection) -> some View {
        let present = tracks(in: collection)
        return NavigationLink(value: collection) {
            HStack(spacing: 12) {
                ArtworkView(
                    url: present.first.flatMap { store.artworkURL(for: $0, width: Design.ArtworkWidth.thumbnail) },
                    cornerRadius: Design.Radius.thumbnail
                )
                .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)

                VStack(alignment: .leading, spacing: 2) {
                    Text(collection.name)
                        .lineLimit(1)
                    Text(collectionDetail(collection, present: present.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                index.remove(collection, deletingFilesWith: downloads)
            }
        }
    }

    private func collectionDetail(_ collection: DownloadedCollection, present: Int) -> String {
        let count = "\(present) song\(present == 1 ? "" : "s")"
        // Says when a download is only partly here, because "twelve songs" over an
        // album that has fourteen is the kind of thing noticed on a plane.
        let missing = collection.trackIds.count - present
        let coverage = missing > 0 ? " · \(missing) missing" : ""
        if let subtitle = collection.subtitle, !subtitle.isEmpty {
            return "\(subtitle) · \(count)\(coverage)"
        }
        return count + coverage
    }

    /// The collection's tracks that are on disk, in the collection's order.
    private func tracks(in collection: DownloadedCollection) -> [JellyfinItem] {
        let byId = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return collection.trackIds.compactMap { byId[$0] }
    }

    /// The play source stays `.unknown` — "downloaded" is a property of the file, not
    /// somewhere the listener browsed, and there is no word for it in the history.
    private func play(_ track: JellyfinItem, in queue: [JellyfinItem]) {
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

/// One downloaded album or playlist: its songs, in its order, all playable offline.
struct DownloadedCollectionView: View {
    let collection: DownloadedCollection

    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = DownloadStore.shared
    @State private var index = DownloadIndex.shared
    @State private var isConfirmingRemove = false

    private var tracks: [JellyfinItem] {
        let byId = Dictionary(
            index.tracks.filter { downloads.state(for: $0.id).isPresent }.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return collection.trackIds.compactMap { byId[$0] }
    }

    var body: some View {
        List {
            ForEach(tracks) { track in
                SongRow(song: track)
                    .contentShape(.rect)
                    .onTapGesture { play(track) }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .swipeActions {
                        Button("Remove", role: .destructive) { downloads.remove(track.id) }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Play", systemImage: "play.fill") {
                        store.play(tracks, from: collection.kind == .album ? .album : .playlist)
                    }
                    Button("Shuffle", systemImage: "shuffle") {
                        store.play(tracks, shuffled: true, from: collection.kind == .album ? .album : .playlist)
                    }
                    Divider()
                    Button("Remove Download", systemImage: "trash", role: .destructive) {
                        isConfirmingRemove = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Options")
            }
        }
        .confirmationDialog(
            "Remove “\(collection.name)” from this device?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                index.remove(collection, deletingFilesWith: downloads)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Songs that are also in another download stay. The music stays on your server either way.")
        }
    }

    private func play(_ track: JellyfinItem) {
        let queue = tracks
        guard let start = queue.firstIndex(where: { $0.id == track.id }) else { return }
        store.play(queue, startingAt: start, from: collection.kind == .album ? .album : .playlist)
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
    /// Albums and playlists downloaded whole. See ``DownloadedCollection``.
    private(set) var collections: [DownloadedCollection] = []

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-tracks.json")
    }()

    @ObservationIgnored private let collectionsURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("downloaded-collections.json")
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

    /// Remembers a collection, replacing an earlier record of the same one — a
    /// playlist re-downloaded after being edited should list what it holds now.
    func record(_ collection: DownloadedCollection) {
        collections.removeAll { $0.id == collection.id }
        collections.append(collection)
        saveCollections()
    }

    /// Forgets a collection and deletes its files, except the ones another downloaded
    /// collection still lists. A song in a downloaded album *and* a downloaded
    /// playlist was asked for twice; removing one of them is not asking for the
    /// song to go.
    func remove(_ collection: DownloadedCollection, deletingFilesWith downloads: DownloadStore) {
        collections.removeAll { $0.id == collection.id }
        let stillWanted = Set(collections.flatMap(\.trackIds))
        for trackId in collection.trackIds where !stillWanted.contains(trackId) {
            downloads.remove(trackId)
        }
        saveCollections()
    }

    /// Drops collections none of whose files remain.
    func prune(keeping present: Set<String>) {
        let before = collections.count
        collections.removeAll { !$0.trackIds.contains(where: present.contains) }
        if collections.count != before { saveCollections() }
    }

    func removeAll() {
        tracks = []
        collections = []
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: collectionsURL)
    }

    private func load() {
        // A plain coder, not the package's Jellyfin one: this is our own round trip,
        // so the keys are already exactly what `JellyfinItem` encodes. The Jellyfin
        // decoder exists to absorb the server's PascalCase, which never applies here.
        if let data = try? Data(contentsOf: url) {
            tracks = (try? JSONDecoder().decode([JellyfinItem].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: collectionsURL) {
            collections = (try? JSONDecoder().decode([DownloadedCollection].self, from: data)) ?? []
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: collectionsURL, options: .atomic)
    }
}
