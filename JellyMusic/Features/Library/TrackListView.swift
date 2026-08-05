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

    private var engine: PlaybackEngine { .shared }

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
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(
                        track: track,
                        position: source.showsTrackNumbers ? track.indexNumber : index + 1,
                        isCurrent: engine.currentTrack?.id == track.id
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
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(url: store.artworkURL(for: artworkItem, width: 800), cornerRadius: 8)
                .frame(maxWidth: 280)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            VStack(spacing: 2) {
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
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }

            HStack(spacing: 12) {
                Button {
                    store.play(tracks)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    store.play(tracks, shuffled: true)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(tracks.isEmpty)
            .padding(.top, 4)
        }
        .padding(.horizontal)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
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
