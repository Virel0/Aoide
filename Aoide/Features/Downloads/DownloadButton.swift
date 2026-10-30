import MeleteKit
import SwiftUI

/// The download control on an album or playlist page.
///
/// Shows one state for the whole collection rather than per track, because that is
/// how someone thinks about it — you download *an album*, not sixteen files. The
/// aggregate is deliberately strict: it only reads as downloaded when every track
/// is, so a half-finished album never looks safe to fly with.
struct CollectionDownloadButton: View {
    let tracks: [MusicItem]
    /// What these tracks are as a whole, so the Downloads screen can file them
    /// under it. Nil for a set that is nobody's album or playlist.
    var collection: DownloadedCollection?

    @Environment(LibraryStore.self) private var library
    @State private var downloads = DownloadStore.shared

    private var audio: [MusicItem] { tracks.filter { $0.type == .audio } }

    private var completed: Int {
        audio.filter { downloads.state(for: $0.id).isPresent }.count
    }

    private var busy: Int {
        audio.filter { downloads.state(for: $0.id).isBusy }.count
    }

    private var allPresent: Bool { !audio.isEmpty && completed == audio.count }

    var body: some View {
        Button {
            if allPresent {
                if let collection {
                    DownloadIndex.shared.remove(collection, deletingFilesWith: downloads)
                } else {
                    for track in audio { downloads.remove(track.id) }
                }
            } else {
                library.download(audio, in: collection)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(label)
            }
            .font(.footnote.weight(.medium))
        }
        .buttonStyle(.bordered)
        .clipShape(.capsule)
        .disabled(audio.isEmpty)
        .accessibilityLabel(allPresent ? "Remove download" : "Download")
        // A complete set is this collection whether or not it was downloaded as one:
        // tracks fetched one at a time before collections existed, or an album
        // finished from two different pages, both file themselves here the first
        // time the page sees every file present.
        .onChange(of: allPresent, initial: true) { _, complete in
            guard complete, let collection else { return }
            DownloadIndex.shared.record(collection)
        }
    }

    private var symbol: String {
        if allPresent { return "checkmark.circle.fill" }
        if busy > 0 { return "arrow.down.circle" }
        return "arrow.down.circle"
    }

    private var label: String {
        if allPresent { return "Downloaded" }
        if busy > 0 { return "Downloading \(completed + 1) of \(audio.count)" }
        if completed > 0 { return "Finish download" }
        return "Download"
    }
}

/// Per-song download control at the trailing edge of a track row.
///
/// This started as status-only, which made single-song downloads reachable purely
/// by long-pressing a row — a gesture nobody discovers. It is now a real control in
/// the states where acting is safe: start a download, or cancel one in flight.
///
/// Tapping a *finished* download deliberately does nothing. It sits inches from the
/// row that starts playback, and silently deleting a file on a mis-tap is a far
/// worse outcome than making removal take a long-press, where the menu says
/// "Remove Download" in words.
struct TrackDownloadBadge: View {
    let trackId: String
    let track: MusicItem

    @State private var downloads = DownloadStore.shared
    /// Optional so the debug harness can render this without a signed-in store.
    /// The non-optional form traps on a missing value rather than yielding nil.
    @Environment(LibraryStore.self) private var store: LibraryStore?

    var body: some View {
        Group {
            switch downloads.state(for: trackId) {
            case .absent:
                button("Download \(track.name)") { store?.download([track]) } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.body)
                        // Quaternary because this repeats on every row of a long
                        // album and has to stay quieter than the song titles.
                        .foregroundStyle(.quaternary)
                }
            case .downloading(let fraction):
                button("Cancel download of \(track.name)") { downloads.cancelDownload(trackId) } label: {
                    ProgressView(value: fraction)
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                }
            case .waiting:
                button("Cancel download of \(track.name)") { downloads.cancelDownload(trackId) } label: {
                    ProgressView().controlSize(.mini)
                }
            case .failed:
                button("Retry download of \(track.name)") { store?.download([track]) } label: {
                    Image(systemName: "exclamationmark.circle")
                        .font(.body)
                        .foregroundStyle(.orange)
                }
            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded")
            }
        }
        // A fixed frame so titles and durations don't shift sideways as a row moves
        // between states, and so the tap target clears the row beneath it.
        .frame(width: 32, height: 32)
    }

    private func button(
        _ label: String,
        action: @escaping () -> Void,
        @ViewBuilder label content: () -> some View
    ) -> some View {
        Button(action: action, label: content)
            .buttonStyle(.plain)
            .contentShape(.rect)
            .accessibilityLabel(label)
    }
}
