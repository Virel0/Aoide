import CurationKit
import JellyfinKit
import SwiftUI

/// Everything called a playlist, in one place.
///
/// There are two kinds and they are genuinely different things: the ones made here live
/// in this device's own database, sync between the listener's devices, and can be smart;
/// the ones on Jellyfin were made on the server, are shared with every other client, and
/// this app can only read them.
///
/// They are presented as two labelled sections of one screen rather than two rows in
/// Library. A listener has one mental category — "my playlists" — and two Library rows
/// both spelled playlist-something would make them guess which is which every single
/// time, before they know what the difference is. Sections put the distinction exactly
/// where it becomes relevant: at the moment you look at a specific playlist and find that
/// one of them offers Rename and Delete and the other doesn't. They are never merged into
/// one list — that would be the genuinely confusing option, because the two behave
/// differently and nothing on a merged row could explain why.
///
/// The order matters too. Local first: they are the only ones this screen can create, and
/// the server's are still one glance away.
struct PlaylistsHomeView: View {
    /// `nil` at the root. A folder pushes the same screen scoped to its contents, so
    /// there is one implementation of a playlist row rather than two that drift.
    var folder: Folder?

    @Environment(LibraryStore.self) private var library
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var indexer = SongIndexer.shared
    @State private var sync = SyncCoordinator.shared

    @State private var draftName = ""
    @State private var isCreatingPlaylist = false
    @State private var isCreatingFolder = false
    @State private var isRenaming = false
    @State private var renameTarget: RenameTarget?
    @State private var deleteTarget: RenameTarget?
    /// The server playlist whose local copy is about to be replaced.
    @State private var refreshing: JellyfinItem?
    @State private var isConfirmingImportAll = false
    @State private var isImportingAll = false
    @State private var importSummary: LocalPlaylistStore.ImportSummary?
    @State private var isConfirmingDelete = false
    @State private var isBuildingSmart = false
    @State private var errorMessage: String?

    private enum RenameTarget {
        case playlist(Playlist)
        case folder(Folder)

        var name: String {
            switch self {
            case .playlist(let list): list.name
            case .folder(let folder): folder.name
            }
        }
    }

    private var localPlaylists: [Playlist] { playlists.playlists(in: folder?.id) }
    private var childFolders: [Folder] { playlists.folders(in: folder?.id) }

    var body: some View {
        List {
            localSection
            // Only at the root: a folder holds local playlists, and repeating the whole
            // server list inside every one of them would say something untrue about
            // where those playlists are filed.
            if folder == nil { serverSection }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(folder?.name ?? "Playlists")
        .confirmationDialog(
            "Copy your Jellyfin playlists?",
            isPresented: $isConfirmingImportAll,
            titleVisibility: .visible
        ) {
            Button("Copy") {
                if case .loaded(let server) = library.playlists { importAll(server) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Says what it will not touch, because that is the worry: a bulk
            // button over playlists somebody has already edited reads as
            // destructive even when it isn't.
            Text("Each one becomes a playlist you can edit here. Copies you already have are left alone, including anything you've changed in them.")
        }
        .alert(
            "Copied",
            isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } })
        ) {
            Button("OK") { importSummary = nil }
        } message: {
            Text(summaryMessage)
        }
        .confirmationDialog(
            "Replace the copy of “\(refreshing?.name ?? "")”?",
            isPresented: Binding(get: { refreshing != nil }, set: { if !$0 { refreshing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                guard let target = refreshing else { return }
                refreshing = nil
                Task { await playlists.importFromServer(target) }
            }
            Button("Cancel", role: .cancel) { refreshing = nil }
        } message: {
            // Spelled out because it cannot be undone: a copy is a snapshot, and
            // refreshing takes the server's contents whole rather than merging.
            Text("This takes the songs from your server again. Anything you've added or reordered in your copy will be lost.")
        }
        .navigationBarTitleDisplayMode(folder == nil ? .automatic : .inline)
        .toolbar { toolbar }
        .task {
            await playlists.reload()
            if folder == nil { await library.loadPlaylistsIfNeeded() }
        }
        .refreshable {
            await playlists.reload()
            if folder == nil { await library.reloadPlaylists() }
        }
        // A sync that landed another device's playlists wrote them straight into the
        // database, which this screen read once in `.task` and has held as an array
        // ever since. `.task` does not run again when the app comes back from the
        // background, and that is precisely when a sync brings changes in.
        .onChange(of: sync.appliedRevision) { _, _ in
            Task { await playlists.reload() }
        }
        .alert("New Playlist", isPresented: $isCreatingPlaylist) {
            TextField("Name", text: $draftName)
            Button("Create") {
                let name = cleaned(draftName)
                guard !name.isEmpty else { return }
                Task { await playlists.createPlaylist(name: name, folderId: folder?.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Name", text: $draftName)
            Button("Create") {
                let name = cleaned(draftName)
                guard !name.isEmpty else { return }
                Task { await playlists.createFolder(name: name, parentId: folder?.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Folders group playlists. Deleting one keeps everything inside it.")
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                let name = cleaned(draftName)
                guard !name.isEmpty, let renameTarget else { return }
                Task {
                    switch renameTarget {
                    case .playlist(let list): await playlists.rename(list, to: name)
                    case .folder(let folder): await playlists.rename(folder, to: name)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            deleteTarget.map { "Delete “\($0.name)”?" } ?? "Delete?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                Task {
                    switch deleteTarget {
                    case .playlist(let list): await playlists.delete(list)
                    case .folder(let folder): await playlists.delete(folder)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .folder = deleteTarget {
                Text("The playlists inside it are kept — they move up one level.")
            } else {
                Text("The songs stay in your library. Only the playlist goes.")
            }
        }
        .sheet(isPresented: $isBuildingSmart) {
            // A sheet is an environment boundary, and this one is presented from a
            // modifier attached above nothing that injects — so both stores are handed
            // over explicitly rather than trusted to be inherited. A missing
            // `@Environment` observable is a crash, not a nil.
            SmartPlaylistEditorView(playlist: nil, folderId: folder?.id)
                .environment(library)
                .environment(playlists)
        }
        .alert(
            "Something didn't save",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: playlists.lastErrorMessage) { _, message in
            guard let message else { return }
            errorMessage = message
            playlists.lastErrorMessage = nil
        }
    }

    // MARK: - Local

    @ViewBuilder
    private var localSection: some View {
        Section {
            if !playlists.isAvailable {
                // Honest rather than empty. The store being nil is the one state that
                // isn't the listener's doing and can't be fixed by tapping anything.
                Label(LocalPlaylistStore.unavailableMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            } else if !playlists.hasLoaded {
                LoadingRow()
            } else if childFolders.isEmpty && localPlaylists.isEmpty {
                emptyLocalState
            } else {
                ForEach(childFolders, id: \.id) { child in
                    folderRow(child)
                }
                ForEach(localPlaylists, id: \.id) { list in
                    playlistRow(list)
                }
            }

            // Draws nothing unless a pass is actually running, so it costs no row the
            // rest of the time.
            indexRow
        } header: {
            Text(folder == nil ? "My Playlists" : "In This Folder")
        } footer: {
            if folder == nil, playlists.isAvailable {
                // A plain list draws footers at body size in the primary colour, which
                // reads as content rather than as a note about the section above it.
                Text("Kept on your device. Smart playlists update themselves from what you actually listen to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyLocalState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No playlists yet.")
                .font(.headline)
            Text("Make one by hand, or let a smart playlist build itself from your listening.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("New Playlist") { beginCreatingPlaylist() }
                    .buttonStyle(.bordered)
                Button("Smart Playlist") { isBuildingSmart = true }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var indexRow: some View {
        switch indexer.state {
        case .running(let indexed):
            HStack(spacing: 10) {
                ProgressView()
                Text("Indexing your library — \(indexed) songs")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
        default:
            EmptyView()
        }
    }

    private func folderRow(_ child: Folder) -> some View {
        NavigationLink {
            PlaylistsHomeView(folder: child)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                    .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    Text(child.name)
                    Text(folderSubtitle(child))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { beginRenaming(.folder(child)) }
            Button("Delete", systemImage: "trash", role: .destructive) { beginDeleting(.folder(child)) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { beginDeleting(.folder(child)) }
        }
    }

    private func folderSubtitle(_ child: Folder) -> String {
        let lists = playlists.playlists(in: child.id).count
        let folders = playlists.folders(in: child.id).count
        var parts: [String] = []
        if lists > 0 { parts.append("\(lists) playlist\(lists == 1 ? "" : "s")") }
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    private func playlistRow(_ list: Playlist) -> some View {
        NavigationLink {
            LocalPlaylistDetailView(playlist: list)
        } label: {
            HStack(spacing: 12) {
                PlaylistArtwork(playlist: list, albumIds: playlists.coverAlbums[list.id] ?? [])
                    .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    Text(list.name)
                        .lineLimit(1)
                    Text(playlistSubtitle(list))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { beginRenaming(.playlist(list)) }
            moveMenu(for: list)
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { beginDeleting(.playlist(list)) }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { beginDeleting(.playlist(list)) }
        }
    }

    private func playlistSubtitle(_ list: Playlist) -> String {
        var parts: [String] = []
        if list.isSmart { parts.append("Smart") }
        if let count = playlists.trackCounts[list.id] {
            parts.append("\(count) song\(count == 1 ? "" : "s")")
        }
        if let notes = list.notes, !notes.isEmpty { parts.append(notes) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func moveMenu(for list: Playlist) -> some View {
        // Only worth offering once a folder exists — otherwise it's a menu whose every
        // entry is the place the playlist already is.
        if !playlists.folders.isEmpty {
            Menu("Move to Folder", systemImage: "folder") {
                Button("None") {
                    Task { await playlists.move(list, toFolder: nil) }
                }
                ForEach(playlists.folders, id: \.id) { destination in
                    Button(destination.name) {
                        Task { await playlists.move(list, toFolder: destination.id) }
                    }
                }
            }
        }
    }

    /// Reports failures rather than only successes. A bulk copy that silently lost
    /// three playlists to a server hiccup is worse than one that says so.
    private var summaryMessage: String {
        guard let summary = importSummary else { return "" }
        var parts = ["\(summary.copied) playlist\(summary.copied == 1 ? "" : "s") copied"]
        if summary.skipped > 0 { parts.append("\(summary.skipped) already here") }
        if summary.failed > 0 { parts.append("\(summary.failed) couldn't be read") }
        return parts.joined(separator: " · ")
    }

    /// Server playlists with no copy here yet. The count is on the button because
    /// "copy everything" reads as destructive when some of it is already here, and
    /// nothing is going to be overwritten.
    private func uncopied(from serverPlaylists: [JellyfinItem]) -> Int {
        serverPlaylists.count { !playlists.importedSourceIds.contains($0.id) }
    }

    private func importAll(_ serverPlaylists: [JellyfinItem]) {
        isImportingAll = true
        Task {
            importSummary = await playlists.importAllFromServer(serverPlaylists)
            isImportingAll = false
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverSection: some View {
        Section {
            switch library.playlists {
            case .idle, .loading:
                LoadingRow()
            case .failed(let message):
                // Not `loadPlaylistsIfNeeded` — its `.idle` guard makes it a no-op from a
                // failed state, which is exactly when this button is on screen.
                ErrorRow(message: message) { Task { await library.reloadPlaylists() } }
            case .loaded(let serverPlaylists):
                if !serverPlaylists.isEmpty, uncopied(from: serverPlaylists) > 0 {
                    Button {
                        isConfirmingImportAll = true
                    } label: {
                        Label(
                            "Copy \(uncopied(from: serverPlaylists)) to My Playlists",
                            systemImage: "square.and.arrow.down.on.square"
                        )
                    }
                    .disabled(isImportingAll)
                }
                if serverPlaylists.isEmpty {
                    Text("Playlists you create on your Jellyfin server show up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(serverPlaylists) { playlist in
                        serverRow(playlist)
                    }
                }
            }
        } header: {
            Text("On Your Server")
        } footer: {
            Text("Made on Jellyfin and shared with every client. Read-only here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func serverRow(_ playlist: JellyfinItem) -> some View {
        // Declared before the row so the confirmation can live on the list rather than
        // on a context menu that is already gone by the time its action runs.

        NavigationLink {
            TrackListView(
                title: playlist.name,
                artworkItem: playlist,
                source: .playlist(playlist.id)
            )
        } label: {
            HStack(spacing: 12) {
                ArtworkView(
                    url: library.artworkURL(for: playlist, width: Design.ArtworkWidth.thumbnail),
                    cornerRadius: Design.Radius.thumbnail
                )
                .frame(width: Design.Size.listThumbnail, height: Design.Size.listThumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).lineLimit(1)
                    if !playlist.subtitle.isEmpty {
                        Text(playlist.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if playlists.importedSourceIds.contains(playlist.id) {
                    // Says which server playlists already have a copy, so importing
                    // the same one twice is a decision rather than an accident.
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Already copied")
                }
            }
        }
        .contextMenu {
            if playlists.importedSourceIds.contains(playlist.id) {
                Button("Refresh Copy", systemImage: "arrow.clockwise") {
                    refreshing = playlist
                }
            } else {
                Button("Copy to My Playlists", systemImage: "square.and.arrow.down") {
                    Task { await playlists.importFromServer(playlist) }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New Playlist", systemImage: "music.note.list") { beginCreatingPlaylist() }
                Button("New Smart Playlist", systemImage: "wand.and.stars") { isBuildingSmart = true }
                Button("New Folder", systemImage: "folder.badge.plus") { beginCreatingFolder() }

                if folder == nil {
                    Divider()
                    Button("Update Song Index", systemImage: "arrow.clockwise") {
                        Task { await SongIndexer.shared.index(library: library) }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New")
            .disabled(!playlists.isAvailable)
        }
    }

    // MARK: - Helpers

    private func cleaned(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func beginCreatingPlaylist() {
        draftName = ""
        isCreatingPlaylist = true
    }

    private func beginCreatingFolder() {
        draftName = ""
        isCreatingFolder = true
    }

    private func beginRenaming(_ target: RenameTarget) {
        renameTarget = target
        draftName = target.name
        isRenaming = true
    }

    private func beginDeleting(_ target: RenameTarget) {
        deleteTarget = target
        isConfirmingDelete = true
    }
}

/// The cover a local playlist gets, since it has none.
///
/// Generated rather than borrowed from the first track: a playlist's contents change, and
/// a cover that changes with them stops being how the listener recognises it in a list.
/// The hue is derived from the name, so the same playlist is the same colour on every
/// launch — Swift's own `hashValue` is seeded per process and would differ between runs.
///
/// Kept inside a narrow band around the app's violet rather than spanning the wheel. A
/// list of playlists is a list of the listener's own things and should read as one family;
/// full-spectrum tiles would compete with the album art two rows below.
struct LocalPlaylistTile: View {
    let name: String
    var isSmart: Bool = false
    var cornerRadius: CGFloat = Design.Radius.thumbnail

    private var hue: Double {
        let sum = name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        // 0.72–0.84: blue-violet through magenta-violet.
        return 0.72 + Double(sum % 120) / 1000
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: hue, saturation: 0.55, brightness: 0.62),
                    Color(hue: min(hue + 0.06, 0.95), saturation: 0.68, brightness: 0.36),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: isSmart ? "wand.and.stars" : "music.note.list")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
