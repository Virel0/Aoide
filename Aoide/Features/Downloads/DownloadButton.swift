import JellyfinKit
import SwiftUI

/// The download control on an album or playlist page.
///
/// Shows one state for the whole collection rather than per track, because that is
/// how someone thinks about it — you download *an album*, not sixteen files. The
/// aggregate is deliberately strict: it only reads as downloaded when every track
/// is, so a half-finished album never looks safe to fly with.
struct CollectionDownloadButton: View {
    let tracks: [JellyfinItem]

    @Environment(LibraryStore.self) private var library
    @State private var downloads = DownloadStore.shared

    private var audio: [JellyfinItem] { tracks.filter { $0.type == .audio } }

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
                for track in audio { downloads.remove(track.id) }
            } else {
                library.download(audio)
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

/// The per-track indicator in a list. Deliberately not a button — a whole row is
/// already a play target, and a second tap target inside it is a mis-tap waiting to
/// happen while driving.
struct TrackDownloadBadge: View {
    let trackId: String
    @State private var downloads = DownloadStore.shared

    var body: some View {
        switch downloads.state(for: trackId) {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Downloaded")
        case .downloading(let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .accessibilityLabel("Downloading")
        case .waiting:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Waiting to download")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Download failed")
        case .absent:
            EmptyView()
        }
    }
}
