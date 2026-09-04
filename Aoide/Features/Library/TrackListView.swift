import CurationKit
import JellyfinKit
import PlaybackKit
import SwiftUI

/// The album / playlist page: big cover, Play and Shuffle, then the tracks.
/// One view serves both because they differ only in where the tracks come from
/// and whether track numbers make sense.
struct TrackListView: View {
    enum Source {
        case album(String)
        case playlist(String)

        var showsTrackNumbers: Bool {
            if case .album = self { return true }
            return false
        }

        /// How the local history files a play started from this page.
        var playSource: PlaySource {
            switch self {
            case .album: .album
            case .playlist: .playlist
            }
        }
    }

    let title: String
    let artworkItem: JellyfinItem
    let source: Source
    var subtitle: String?

    @Environment(LibraryStore.self) private var store
    @Environment(LocalPlaylistStore.self) private var playlists
    @State private var downloads = DownloadStore.shared
    @State private var adding: TrackSelection?
    @State private var tracks: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var palette: ArtworkPalette?
    @State private var isFavorite = false

    private var engine: PlaybackEngine { .shared }

    /// Albums pressed to more than one disc need their track numbers explained —
    /// otherwise numbering restarts at 1 partway down the page with no reason given.
    /// A personal FLAC library is exactly the kind that holds box sets.
    private var discs: [(number: Int?, tracks: [JellyfinItem])] {
        // Disc headers are meaningless on a playlist, and grouping one by the disc
        // numbers its tracks happen to carry would scatter it into nonsense.
        guard source.showsTrackNumbers else { return [] }

        let numbers = Set(tracks.compactMap(\.parentIndexNumber))
        guard numbers.count > 1 else { return [] }

        var sections: [(number: Int?, tracks: [JellyfinItem])] = numbers.sorted().map { disc in
            (disc, tracks.filter { $0.parentIndexNumber == disc })
        }
        // A track with no disc tag matched no section and rendered nowhere —
        // silently missing from the page. A personal library with hand-tagged rips
        // hits this constantly.
        let untagged = tracks.filter { $0.parentIndexNumber == nil }
        if !untagged.isEmpty { sections.append((nil, untagged)) }
        return sections
    }

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)

            if isLoading {
                LoadingRow()
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else if tracks.isEmpty {
                Text("No songs here.")
                    .foregroundStyle(.secondary)
            } else if discs.isEmpty {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(for: track, at: index)
                }
            } else {
                ForEach(discs, id: \.number) { disc in
                    Section {
                        ForEach(disc.tracks, id: \.id) { track in
                            row(for: track, at: tracks.firstIndex { $0.id == track.id } ?? 0)
                        }
                    } header: {
                        Text(disc.number.map { "Disc \($0)" } ?? "Other")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        // One sheet for the whole page rather than one per row: a context menu is gone
        // before its action runs, so the presentation has to live on something that is
        // still on screen. Both stores are handed in explicitly — a sheet is an
        // environment boundary, and a missing `@Environment` observable is a crash.
        .sheet(item: $adding) { selection in
            AddToPlaylistSheet(selection: selection)
                .environment(store)
                .environment(playlists)
        }
        .task { await load() }
        .task(id: artworkItem.id) {
            isFavorite = artworkItem.userData?.isFavorite ?? false
            guard let url = store.artworkURL(for: artworkItem, width: Design.ArtworkWidth.card) else { return }
            palette = await ArtworkColorExtractor.shared.palette(for: url)
        }
    }

    private func row(for track: JellyfinItem, at index: Int) -> some View {
        TrackRow(
            track: track,
            position: source.showsTrackNumbers ? track.indexNumber : index + 1,
            isCurrent: engine.currentTrack?.id == track.id,
            // A various-artists compilation is unreadable without the artist on
            // each row, even though an ordinary album doesn't want it.
            showsArtist: !source.showsTrackNumbers || isCompilation
        )
        .contentShape(.rect)
        .onTapGesture {
            store.play(tracks, startingAt: index, from: source.playSource)
            remember()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { store.play(tracks, startingAt: index, from: source.playSource) }
        // Combining the row's children collapses the download control into the row,
        // so VoiceOver can no longer reach it by touch. Naming it as a row action
        // puts it back — without this the control is sighted-only.
        .accessibilityAction(named: downloads.state(for: track.id).isPresent ? "Remove Download" : "Download") {
            if downloads.state(for: track.id).isPresent {
                downloads.remove(track.id)
            } else {
                store.download([track])
            }
        }
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                store.playNext([track], from: source.playSource)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                store.addToQueue([track], from: source.playSource)
            }
            Button("Favourite", systemImage: "heart") {
                Task { await store.toggleFavorite(track) }
            }
            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                adding = TrackSelection([track])
            }

            Divider()

            TasteFlagButtons(track: track)

            Divider()

            // This menu was missing a download entry entirely, which is why single
            // songs looked undownloadable: the only per-track affordance lived on a
            // different menu used by other screens.
            if downloads.state(for: track.id).isPresent {
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.remove(track.id)
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    store.download([track])
                }
            }
        }
    }

    /// More than a couple of distinct credited artists means this is a compilation
    /// rather than one artist's record.
    private var isCompilation: Bool {
        Set(tracks.compactMap { $0.albumArtist ?? $0.artists.first }).count > 2
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(
                url: store.artworkURL(for: artworkItem, width: Design.ArtworkWidth.hero),
                cornerRadius: Design.Radius.hero
            )
            .frame(maxWidth: 260)
            .shadow(color: .black.opacity(0.28), radius: 18, y: 10)

            VStack(spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let subtitle = subtitle ?? nonEmptySubtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .multilineTextAlignment(.center)
                }

                if let detail = detailLine {
                    Text(detail.uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .tracking(0.4)
                        .padding(.top, 3)
                }
            }

            actionRow
            CollectionDownloadButton(tracks: tracks, collection: downloadCollection)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        // The artwork wash. Fades out down the page so the track list sits on the
        // ordinary background and stays readable.
        .background {
            if let tint = palette?.tint {
                LinearGradient(
                    colors: [tint.opacity(0.55), tint.opacity(0.16), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.45), value: palette)
    }

    private var actionRow: some View {
        DetailActionRow(
            isFavorite: isFavorite,
            isEnabled: !tracks.isEmpty,
            // Shuffle is still the album (or the playlist): it says how these tracks
            // are being played, not where they came from.
            onLeading: { store.play(tracks, shuffled: true, from: source.playSource); remember() },
            onPlay: { store.play(tracks, from: source.playSource); remember() },
            onTrailing: {
                // Drive from local intent and adopt what the server confirms.
                // Deriving the new value from `artworkItem.userData` read a snapshot
                // frozen when the list was fetched, so the glyph never moved and a
                // second tap re-sent the same value.
                let desired = !isFavorite
                isFavorite = desired
                Task { isFavorite = await store.toggleFavorite(artworkItem, to: desired) }
            }
        )
        .padding(.top, 6)
    }

    /// This page as a thing Home can offer to resume.
    private func remember() {
        let kind: RecentContext.Kind
        let id: String
        switch source {
        case .album(let albumId): kind = .album; id = albumId
        case .playlist(let playlistId): kind = .jellyfinPlaylist; id = playlistId
        }
        store.remember(RecentContext(
            kind: kind, id: id, name: title, subtitle: subtitle ?? nonEmptySubtitle,
            artworkItemId: artworkItem.id, lastOpened: Date().millis
        ))
    }

    /// This page as a thing the Downloads screen can file its songs under.
    private var downloadCollection: DownloadedCollection {
        switch source {
        case .album(let id):
            DownloadedCollection(
                id: id, kind: .album, name: title,
                subtitle: subtitle ?? nonEmptySubtitle,
                trackIds: tracks.filter { $0.type == .audio }.map(\.id)
            )
        case .playlist(let id):
            DownloadedCollection(
                id: id, kind: .playlist, name: title, subtitle: nil,
                trackIds: tracks.filter { $0.type == .audio }.map(\.id)
            )
        }
    }

    private var nonEmptySubtitle: String? {
        let text = artworkItem.subtitle
        return text.isEmpty ? nil : text
    }

    /// "2019 · 12 songs · 48 minutes", skipping whatever the server didn't give us.
    private var detailLine: String? {
        var parts: [String] = []
        if let year = artworkItem.productionYear { parts.append(String(year)) }
        if !tracks.isEmpty { parts.append("\(tracks.count) song\(tracks.count == 1 ? "" : "s")") }

        let total = tracks.compactMap(\.duration).reduce(Duration.zero, +)
        if total > .zero, let formatted = total.approximateDescription {
            parts.append(formatted)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            switch source {
            case .album(let id):
                tracks = try await store.tracks(inAlbum: id)
            case .playlist(let id):
                tracks = try await store.tracks(inPlaylist: id)
            }
        } catch {
            errorMessage = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}

struct AlbumDetailView: View {
    let album: JellyfinItem

    var body: some View {
        TrackListView(
            title: album.name,
            artworkItem: album,
            source: .album(album.id)
        )
    }
}

// MARK: - Track row

struct TrackRow: View {
    let track: JellyfinItem
    var position: Int?
    var isCurrent: Bool = false
    /// Playlists and search results mix albums together, so the artist matters there
    /// in a way it doesn't inside a single album.
    var showsArtist: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    // Apple Music marks the playing row with a speaker rather than
                    // its track number.
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .font(.caption)
                } else if let position {
                    Text("\(position)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline.monospacedDigit())
                }
            }
            .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.name)
                    .lineLimit(1)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                if showsArtist, !track.subtitle.isEmpty {
                    Text(track.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            TrackDownloadBadge(trackId: track.id, track: track)

            if let duration = track.duration {
                Text(duration.clockDescription)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Duration formatting

extension Duration {
    /// `3:07` — how a track length is written next to a song.
    var clockDescription: String {
        let total = Int(components.seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    /// `48 minutes` / `1 hour 12 minutes` — for an album's total running time,
    /// where second-level precision would be noise.
    var approximateDescription: String? {
        let total = Int(components.seconds)
        guard total >= 60 else { return nil }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            let hourPart = "\(hours) hour\(hours == 1 ? "" : "s")"
            return minutes > 0 ? "\(hourPart) \(minutes) minutes" : hourPart
        }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }
}
