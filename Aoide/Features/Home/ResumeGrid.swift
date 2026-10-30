import CurationKit
import MeleteKit
import PlaybackKit
import SwiftUI

/// The top of Home: the last few things you were in, each one tap from playing.
///
/// A queue another device put down more recently than any of them takes the first
/// tile, because that is the thing most likely to be wanted on picking the phone
/// up. Draws nothing until there is something to resume, so a fresh install still
/// opens on its shelves rather than on an explanation.
struct ResumeGrid: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var recents = RecentContextStore.shared
    @State private var sync = SyncCoordinator.shared
    @State private var handoff: QueueState?
    @State private var isResuming = false

    private static let tiles = 6

    private var contexts: [RecentContext] {
        recents.list.latest(handoff == nil ? Self.tiles : Self.tiles - 1)
    }

    var body: some View {
        if handoff != nil || !contexts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    if let handoff {
                        tile(
                            name: "Pick up from \(handoff.deviceName)",
                            detail: "\(handoff.trackIdList.count) tracks",
                            artworkId: handoff.trackIdList.indices.contains(handoff.position) ? handoff.trackIdList[handoff.position] : nil,
                            symbol: "arrow.down.left.circle.fill"
                        ) { Task { await pickUp(handoff) } }
                    }
                    ForEach(contexts) { context in
                        tile(name: context.name, detail: context.subtitle ?? kindLabel(context.kind), artworkId: context.artworkItemId, symbol: symbol(for: context.kind)) {
                            Task { await resume(context) }
                        }
                        .contextMenu {
                            Button("Remove from Recents", systemImage: "xmark.circle") { recents.forget(context) }
                        }
                    }
                }
                .pageMargin()
            }
            .disabled(isResuming)
            .task(id: sync.appliedRevision) { await loadHandoff() }
        }
    }

    private func tile(name: String, detail: String, artworkId: String?, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ArtworkView(
                    url: artworkId.flatMap { store.artworkURL(itemId: $0, maxWidth: Design.ArtworkWidth.thumbnail) },
                    cornerRadius: Design.Radius.thumbnail
                )
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Label(detail, systemImage: symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Design.Radius.thumbnail + 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Resume \(name)")
    }

    private func kindLabel(_ kind: RecentContext.Kind) -> String {
        switch kind {
        case .album: "Album"
        case .jellyfinPlaylist, .localPlaylist: "Playlist"
        case .station: "Station"
        }
    }

    private func symbol(for kind: RecentContext.Kind) -> String {
        switch kind {
        case .album: "square.stack"
        case .jellyfinPlaylist, .localPlaylist: "music.note.list"
        case .station: "dot.radiowaves.left.and.right"
        }
    }

    // MARK: - Doing it

    private func loadHandoff() async {
        guard let db = CurationDatabase.shared else { return }
        let found = try? await Task.detached { try db.resumableQueues().first }.value
        // Only offered when it is newer than anything this device was in; otherwise
        // the phone's own last album is the better first tile.
        if let found, found.updatedAt > (recents.list.contexts.first?.lastOpened ?? 0) {
            handoff = found
        } else {
            handoff = nil
        }
    }

    private func resume(_ context: RecentContext) async {
        isResuming = true
        defer { isResuming = false }
        switch context.kind {
        case .album:
            guard let tracks = try? await store.tracks(inAlbum: context.id) else { return }
            store.play(tracks, from: .album)
        case .jellyfinPlaylist:
            // A playlist on the Jellyfin server Melete replaced: nothing to play.
            recents.forget(context)
            return
        case .localPlaylist:
            guard let playlist = playlists.playlists.first(where: { $0.id == context.id }) else {
                recents.forget(context)
                return
            }
            let contents = await playlists.contents(of: playlist)
            store.play(contents.playbackOrder, from: playlist.isSmart ? .smart : .playlist)
        case .station:
            await store.startStation(seededById: context.id, named: context.name, artworkItemId: context.artworkItemId)
        }
        recents.remember(RecentContext(
            kind: context.kind, id: context.id, name: context.name, subtitle: context.subtitle,
            artworkItemId: context.artworkItemId, lastOpened: Date().millis
        ))
    }

    /// Plays the other device's queue from where it left off.
    private func pickUp(_ queue: QueueState) async {
        isResuming = true
        defer { isResuming = false }
        let ids = queue.trackIdList
        guard let items = try? await store.items(ids: ids) else { return }
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = ids.compactMap { byId[$0] }
        guard !ordered.isEmpty else { return }
        // The position indexes the other device's list; anything it named that this
        // server no longer has shifts it, so it is re-found by id.
        let startId = ids.indices.contains(queue.position) ? ids[queue.position] : ids[0]
        let start = ordered.firstIndex { $0.id == startId } ?? 0
        store.play(ordered, startingAt: start)
        PlaybackEngine.shared.seek(to: .milliseconds(queue.elapsedMs))
        handoff = nil
    }
}
