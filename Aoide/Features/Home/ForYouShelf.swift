import MeleteKit
import SwiftUI

/// Home's For You shelf: songs suggested from what you finished lately, each
/// saying which of your songs or artists it came from.
///
/// A song in the library plays on a tap, followed by the shelf's other songs to
/// play, and holds Play Next, Play Last and the taste flags. One the library
/// doesn't have can be asked for, in Search's words; once asked for (or wanted
/// already) it says so and does nothing on a tap. Draws nothing until the server
/// has a ready list with songs in it.
struct ForYouShelf: View {
    @Environment(LibraryStore.self) private var library
    @State private var forYou = ForYouStore.shared
    /// The song being asked for, by item id.
    @State private var asking: String?
    /// What asking said when it didn't work, by item id.
    @State private var answers: [String: String] = [:]

    var body: some View {
        let items = forYou.items
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                PlainShelfHeader(title: "For You")
                    .pageMargin()

                ScrollView(.horizontal) {
                    // Not lazy: a lazy row takes its height from the cards drawn
                    // so far, and cut off the Ask under cards further along.
                    // Forty at most.
                    HStack(alignment: .top, spacing: Design.Spacing.card) {
                        ForEach(items) { card($0) }
                    }
                    .scrollTargetLayout()
                    .pageMargin()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func card(_ item: ForYouItem) -> some View {
        switch item.offer {
        case .playable(let track):
            playableCard(track, because: item.because.line)
        case .requested(let song, let requestId):
            ForYouCard(cover: poster(song), title: song.title, artist: song.artist, because: item.because.line) {
                // Search's words: asked for by you, else on the wanted list.
                if requestId != nil {
                    badge("Asked For", systemImage: "paperplane")
                } else {
                    badge("Wanted", systemImage: "clock")
                }
            }
        case .requestable(let song):
            ForYouCard(cover: poster(song), title: song.title, artist: song.artist, because: item.because.line) {
                askControl(song, id: item.id)
            }
        }
    }

    private func playableCard(_ track: MusicItem, because: String) -> some View {
        Button {
            play(track)
        } label: {
            ForYouCard(
                cover: library.artworkURL(for: track, width: Design.ArtworkWidth.card),
                title: track.name, artist: track.subtitle, because: because
            ) { EmptyView() }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays it, then the other songs here")
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                library.playNext([track], from: .smart)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                library.addToQueue([track], from: .smart)
            }
            Divider()
            TasteFlagButtons(track: track)
        }
    }

    /// Search's Ask, and in its place what asking said when it didn't work.
    @ViewBuilder
    private func askControl(_ song: ForYouSong, id: String) -> some View {
        if let answer = answers[id] {
            Text(answer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            Button(asking == id ? "Asking…" : "Ask") {
                Task { await ask(song, id: id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(asking != nil)
            .accessibilityLabel("Ask for \(song.title)")
        }
    }

    private func poster(_ song: ForYouSong) -> URL? {
        song.poster.flatMap { AppSession.shared.client?.posterURL($0, maxWidth: Design.ArtworkWidth.card) }
    }

    private func badge(_ words: String, systemImage: String) -> some View {
        Label(words, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func play(_ track: MusicItem) {
        let tracks = forYou.playable
        let index = tracks.firstIndex { $0.id == track.id } ?? 0
        library.play(tracks, startingAt: index, from: .smart)
    }

    private func ask(_ song: ForYouSong, id: String) async {
        guard let client = AppSession.shared.client else { return }
        asking = id
        defer { asking = nil }
        answers[id] = await forYou.ask(for: song, client: client)
    }
}

/// Cover, title, artist, and why it's here; `footer` under them, for asking.
private struct ForYouCard<Footer: View>: View {
    let cover: URL?
    let title: String
    let artist: String
    let because: String
    @ViewBuilder var footer: () -> Footer

    private let width = Design.Size.shelfCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ArtworkView(url: cover, cornerRadius: Design.Radius.card)
                .frame(width: width, height: width)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(because)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .padding(.top, 2)
            }
            .frame(width: width, alignment: .leading)

            footer()
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }
}
