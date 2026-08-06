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
    }

    let title: String
    let artworkItem: JellyfinItem
    let source: Source
    var subtitle: String?

    @Environment(LibraryStore.self) private var store
    @State private var tracks: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var palette: ArtworkPalette?
    @State private var isFavorite = false

    private var engine: PlaybackEngine { .shared }

    /// Albums pressed to more than one disc need their track numbers explained —
    /// otherwise numbering restarts at 1 partway down the page with no reason given.
    /// A personal FLAC library is exactly the kind that holds box sets.
    private var discs: [(number: Int, tracks: [JellyfinItem])] {
        let numbers = Set(tracks.compactMap(\.parentIndexNumber))
        guard numbers.count > 1 else { return [] }
        return numbers.sorted().map { disc in
            (disc, tracks.filter { $0.parentIndexNumber == disc })
        }
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
                        Text("Disc \(disc.number)")
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
            store.play(tracks, startingAt: index)
        }
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                store.playNext([track])
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                store.addToQueue([track])
            }
            Button("Favourite", systemImage: "heart") {
                Task { await store.toggleFavorite(track) }
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

    /// Shuffle left, Play centre, Favourite right — the iOS 26 Apple Music layout,
    /// where Play is the filled capsule and the two flanking controls are circles.
    private var actionRow: some View {
        HStack(spacing: 18) {
            Button {
                store.play(tracks, shuffled: true)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .clipShape(.circle)
            .accessibilityLabel("Shuffle")

            Button {
                store.play(tracks)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.capsule)

            Button {
                Task { await store.toggleFavorite(artworkItem) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .clipShape(.circle)
            .accessibilityLabel(isFavorite ? "Remove from Favourites" : "Add to Favourites")
        }
        .disabled(tracks.isEmpty)
        .padding(.top, 6)
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
