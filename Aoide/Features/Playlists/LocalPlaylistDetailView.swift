import CurationKit
import JellyfinKit
import PlaybackKit
import SwiftUI

/// One local playlist: its songs, playable, reorderable, and — if it's smart — the rules
/// that decide what's in it.
///
/// Not `TrackListView`. That screen is built around a `JellyfinItem` it can ask the server
/// about; this one starts from a row in a local database that holds ids and fingerprints,
/// has to render songs the server can no longer find, and has to be editable. Sharing one
/// view would have meant a pile of flags inside it and two half-right screens.
struct LocalPlaylistDetailView: View {
    let playlist: Playlist

    @Environment(LibraryStore.self) private var library
    @Environment(LocalPlaylistStore.self) private var playlists
    @Environment(\.dismiss) private var dismiss
    @State private var indexer = SongIndexer.shared
    @State private var engine = PlaybackEngine.shared
    @State private var sync = SyncCoordinator.shared

    @State private var contents = PlaylistContents()
    /// The row this screen believes it is showing. Held apart from `playlist` so a rename
    /// or a rule change made here is reflected without going back and in again.
    @State private var current: Playlist
    @State private var isEditingDetails = false
    @State private var isEditingRules = false

    init(playlist: Playlist) {
        self.playlist = playlist
        _current = State(initialValue: playlist)
    }

    /// A play started here is filed under what it actually is. `.smart` exists in the
    /// history for precisely this — a queue nobody hand-picked, assembled by a rule — and
    /// calling it `.playlist` would put songs the listener never chose into "you played
    /// this playlist a lot".
    private var playSource: PlaySource { current.isSmart ? .smart : .playlist }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if let message = contents.offlineMessage {
                Label(message, systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }

            if contents.isLoading {
                LoadingRow()
            } else if let message = contents.errorMessage {
                ErrorRow(message: message) { Task { await load() } }
            } else if contents.tracks.isEmpty {
                emptyState
                    .listRowSeparator(.hidden)
            } else {
                ForEach(contents.tracks) { track in
                    row(track)
                }
                // Reordering is a property of a hand-made playlist. A smart playlist's
                // order comes from its sort rule, so a drag here would be undone the next
                // time it is evaluated — better to not offer it than to offer it and lose
                // the gesture.
                .onMove(perform: moveAction)
                .onDelete(perform: deleteAction)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await load() }
        .task {
            // A smart playlist can only see songs the local index knows about, so this is
            // the moment to make sure it knows about any. Does nothing when the index is
            // already built.
            if current.isSmart { await indexer.indexIfNeeded(library: library) }
        }
        .onChange(of: indexer.state) { _, state in
            // The rules just gained a library to match against; re-evaluate rather than
            // leaving an empty screen that is no longer true.
            if case .finished = state, current.isSmart { Task { await load() } }
        }
        .refreshable { await load() }
        // Another device's edits to this very playlist have just been written under it.
        // Nothing observes those tables, and this screen can be open across a
        // background-and-return, so it would keep drawing rows that are no longer there.
        .onChange(of: sync.appliedRevision) { _, _ in
            Task { await load() }
        }
        .sheet(isPresented: $isEditingDetails) {
            PlaylistDetailsSheet(playlist: current) { name, notes in
                await playlists.rename(current, to: name)
                await playlists.setNotes(notes, on: current)
                current.name = name
                current.notes = notes
            }
            // Explicit, not inherited: a sheet is an environment boundary and a missing
            // `@Environment` observable is a crash rather than a nil.
            .environment(playlists)
        }
        .sheet(isPresented: $isEditingRules) {
            SmartPlaylistEditorView(playlist: current, folderId: current.folderId) { updated in
                current = updated
                Task { await load() }
            }
            .environment(library)
            .environment(playlists)
        }
    }

    // MARK: - Rows

    private func row(_ track: PlaylistTrack) -> some View {
        PlaylistRowView(
            track: track,
            artworkURL: track.item.flatMap {
                library.artworkURL(for: $0, width: Design.ArtworkWidth.thumbnail)
            },
            isCurrent: engine.currentTrack?.id == track.jellyfinId
        )
        .contentShape(.rect)
        .onTapGesture { play(from: track) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { play(from: track) }
        .contextMenu {
            if let item = track.item {
                Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    library.playNext([item], from: playSource)
                }
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    library.addToQueue([item], from: playSource)
                }
                Divider()
            }
            if let itemId = track.itemId {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                    Task { await remove(itemId) }
                }
            }
        }
    }

    /// Both halves read from `contents` at the same instant, which is what keeps a tap
    /// honest after this screen has reordered or deleted a row without reloading.
    private func play(from track: PlaylistTrack) {
        guard let index = contents.playbackIndex(of: track) else { return }
        library.play(contents.playbackOrder, startingAt: index, from: playSource)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            PlaylistHeroArtwork(
                name: current.name,
                isSmart: current.isSmart,
                covers: coverURLs
            )
            .frame(maxWidth: 260)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            VStack(spacing: 3) {
                Text(current.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let notes = current.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(detailLine.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .tracking(0.4)
                    .padding(.top, 3)
            }

            DetailActionRow(
                leadingIcon: "shuffle",
                leadingLabel: "Shuffle",
                trailingIcon: current.isSmart ? "slider.horizontal.3" : "square.and.pencil",
                trailingLabel: current.isSmart ? "Edit Rules" : "Edit Details",
                trailingFills: false,
                isEnabled: !contents.playbackOrder.isEmpty,
                onLeading: { library.play(contents.playbackOrder, shuffled: true, from: playSource) },
                onPlay: { library.play(contents.playbackOrder, from: playSource) },
                onTrailing: { if current.isSmart { isEditingRules = true } else { isEditingDetails = true } }
            )
            .padding(.top, 6)

            if current.isSmart, let summary = ruleSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    /// The first few covers, for the mosaic. Only playable rows have one.
    private var coverURLs: [URL] {
        contents.tracks
            .prefix(12)
            .compactMap(\.item)
            .compactMap { library.artworkURL(for: $0, width: Design.ArtworkWidth.card) }
    }

    private var detailLine: String {
        var parts: [String] = []
        if current.isSmart { parts.append("Smart Playlist") }
        let count = contents.tracks.count
        if let total = contents.totalCount {
            // Said plainly rather than rounded away: these rules match far more than is
            // on screen, and printing the smaller number as if it were the whole
            // playlist would be the screen lying about its own contents.
            parts.append("first \(count) of \(total) songs")
        } else {
            parts.append("\(count) song\(count == 1 ? "" : "s")")
        }
        if let formatted = contents.totalDuration.approximateDescription {
            parts.append(formatted)
        }
        if contents.unplayableCount > 0 {
            parts.append("\(contents.unplayableCount) missing")
        }
        return parts.joined(separator: " · ")
    }

    /// The rules, written out. A smart playlist that won't say what it's doing is a magic
    /// box, and the first question anybody asks of one is "why is that in here".
    private var ruleSummary: String? {
        guard let rules = try? current.smartRuleSet(), !rules.rules.isEmpty else { return nil }
        let joined = rules.rules
            .map(Self.describe)
            .joined(separator: rules.match == .all ? " and " : " or ")
        return "Songs where \(joined)."
    }

    private static func describe(_ rule: SmartRule) -> String {
        let value: String = switch rule.value {
        case .text(let text):
            SmartField.kind(of: rule.field) == .date
                ? (try? RelativeInterval.parse(text)).map {
                    "\($0.amount) \(SmartField.name(of: $0.unit, plural: $0.amount != 1))"
                } ?? text
                : "“\(text)”"
        case .number(let number):
            rule.field == .durationMs ? "\(number / 1000) seconds" : "\(number)"
        case .flag(let flag):
            flag ? "yes" : "no"
        }
        return "\(SmartField.name(of: rule.field).lowercased()) \(SmartField.name(of: rule.op)) \(value)"
    }

    // MARK: - Empty states

    @ViewBuilder
    private var emptyState: some View {
        if current.isSmart {
            if indexer.isRunning {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Indexing your library so these rules have something to match.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 24)
            } else {
                ContentUnavailableView {
                    Label("Nothing Matches Yet", systemImage: "wand.and.stars")
                } description: {
                    Text("Either nothing in your library fits these rules, or you haven't listened enough for them to bite.")
                } actions: {
                    Button("Edit Rules") { isEditingRules = true }
                        .buttonStyle(.bordered)
                    Button("Update Song Index") {
                        Task { await indexer.index(library: library) }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 12)
            }
        } else {
            ContentUnavailableView {
                Label("No Songs Yet", systemImage: "music.note.list")
            } description: {
                Text("Press and hold any song in your library, then choose Add to Playlist.")
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !current.isSmart, contents.tracks.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                // An explicit Edit button rather than relying on a long press. Reordering
                // is the one action here with no other affordance, and a gesture nobody
                // discovers is a feature that isn't there.
                EditButton()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if current.isSmart {
                    Button("Edit Rules", systemImage: "slider.horizontal.3") { isEditingRules = true }
                } else {
                    Button("Rename & Notes", systemImage: "square.and.pencil") { isEditingDetails = true }
                }
                Divider()
                Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                    // Popped as well as deleted. Staying here would leave a whole screen
                    // describing a playlist that no longer exists, whose Play button
                    // still works.
                    Task {
                        await playlists.delete(current)
                        dismiss()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Playlist Options")
        }
    }

    // MARK: - Editing

    private func load() async {
        contents.isLoading = contents.tracks.isEmpty
        contents = await playlists.contents(of: current)
    }

    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard !current.isSmart else { return nil }
        return { source, destination in move(from: source, to: destination) }
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        guard !current.isSmart else { return nil }
        return { offsets in delete(at: offsets) }
    }

    /// Drag-to-reorder, written straight through to the store.
    ///
    /// The subtraction is the whole trick and it is not cosmetic. SwiftUI measures
    /// `destination` in the list *before* the row is taken out, while `moveItem` measures
    /// its index in the list *after* — so a downward drag would land one place short of
    /// where the finger was, every time.
    private func move(from source: IndexSet, to destination: Int) {
        guard let first = source.first, let itemId = contents.tracks[first].itemId else { return }
        let target = destination > first ? destination - 1 : destination

        // Applied locally first so the row stays under the finger. The store writes one
        // row; there is nothing to re-fetch and re-drawing from a round trip would make
        // the list jump.
        contents.tracks.move(fromOffsets: source, toOffset: destination)
        let playlistId = current.id
        Task {
            let moved = await playlists.moveItem(itemId, in: playlistId, to: target)
            // Only on failure. The optimistic order is already right when it worked, and
            // reloading then would cost a round trip to redraw what is on screen.
            if !moved { await load() }
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.compactMap { contents.tracks[$0].itemId }
        contents.tracks.remove(atOffsets: offsets)
        Task {
            for id in ids { await playlists.removeItem(id) }
        }
    }

    private func remove(_ itemId: String) async {
        contents.tracks.removeAll { $0.itemId == itemId }
        await playlists.removeItem(itemId)
    }
}

// MARK: - Row

/// A playlist row, which is not quite a track row.
///
/// It has to draw songs that cannot be played — an entry whose file the server no longer
/// knows — and say so, rather than looking identical to a playable one and doing nothing
/// when tapped.
struct PlaylistRowView: View {
    let track: PlaylistTrack
    let artworkURL: URL?
    var isCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: artworkURL, cornerRadius: Design.Radius.thumbnail)
                .frame(width: 44, height: 44)
                .opacity(track.isPlayable ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .lineLimit(1)
                    .foregroundStyle(titleStyle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }

            // The play count, where it is the reason the row is here at all: a
            // Most Played list without one is an unexplained ranking, and on an ordinary
            // playlist it is the only place in the app that admits how much a song has
            // actually been listened to rather than merely started.
            if track.playCount > 0 {
                Label("\(track.playCount)", systemImage: "play.fill")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .labelStyle(.playCount)
                    .accessibilityLabel("Played \(track.playCount) time\(track.playCount == 1 ? "" : "s")")
            }

            if let duration = track.duration {
                Text(duration.clockDescription)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var titleStyle: AnyShapeStyle {
        if isCurrent { return AnyShapeStyle(.tint) }
        return track.isPlayable ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }

    private var subtitle: String {
        if !track.isPlayable {
            // Two different failures, and the difference is worth a word: one is a file
            // the relink pass has already looked for and not found, the other is a server
            // that simply didn't answer this time.
            return track.isUnresolved ? "Not in your library any more" : "Unavailable right now"
        }
        return track.subtitle
    }
}

/// Glyph and number, tight together — `Label`'s default spacing is meant for a menu row
/// and reads as two separate things at this size.
private struct PlayCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}

private extension LabelStyle where Self == PlayCountLabelStyle {
    static var playCount: PlayCountLabelStyle { PlayCountLabelStyle() }
}

// MARK: - Hero artwork

/// A local playlist has no cover of its own, so it gets one built from what's in it.
///
/// A mosaic of the first four covers where there are four, one cover where there is one,
/// and the generated tile where there is nothing yet — so an empty playlist still looks
/// like a playlist rather than a blank rectangle.
struct PlaylistHeroArtwork: View {
    let name: String
    var isSmart = false
    let covers: [URL]

    var body: some View {
        Group {
            if covers.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ArtworkView(url: covers[0], cornerRadius: 0)
                        ArtworkView(url: covers[1], cornerRadius: 0)
                    }
                    GridRow {
                        ArtworkView(url: covers[2], cornerRadius: 0)
                        ArtworkView(url: covers[3], cornerRadius: 0)
                    }
                }
                .clipShape(.rect(cornerRadius: Design.Radius.hero))
            } else if let first = covers.first {
                ArtworkView(url: first, cornerRadius: Design.Radius.hero)
            } else {
                LocalPlaylistTile(name: name, isSmart: isSmart, cornerRadius: Design.Radius.hero)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: - Details sheet

/// Rename, and the one line of description a playlist is allowed.
///
/// Notes exist in the store and nothing else surfaced them; a playlist called "Sunday" is
/// worth being able to explain to yourself in six months.
struct PlaylistDetailsSheet: View {
    let playlist: Playlist
    let save: @MainActor (String, String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var notes: String

    init(playlist: Playlist, save: @escaping @MainActor (String, String?) async -> Void) {
        self.playlist = playlist
        self.save = save
        _name = State(initialValue: playlist.name)
        _notes = State(initialValue: playlist.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }
                Section("Notes") {
                    TextField("What this playlist is for", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                }
            }
            .navigationTitle("Playlist Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { await save(trimmed, text.isEmpty ? nil : text) }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
