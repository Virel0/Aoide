import MeleteKit
import SwiftUI

/// How the server's making of an imported playlist is going, and the way to it.
struct ServerImportSection: View {
    let serverImport: ServerPlaylistImport

    var body: some View {
        Section {
            switch serverImport.phase {
            case .sending:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sending the playlist to your server…").foregroundStyle(.secondary)
                }
            case .filling(let summary):
                ProgressView(value: Double(summary.handled), total: Double(max(summary.tracks, 1))) {
                    Text("Adding songs… \(summary.handled) of \(summary.tracks)")
                }
            case .done(let summary):
                Label(Self.outcome(summary), systemImage: "checkmark.circle")
            case .unsupported:
                Label(
                    "Your server can't make the playlist itself, so the songs it has were saved. Ask for the missing ones below.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            if let playlist = serverImport.playlist {
                NavigationLink {
                    LocalPlaylistDetailView(playlist: playlist)
                } label: {
                    Label("Open “\(playlist.name)”", systemImage: "music.note.list")
                }
            } else if case .done = serverImport.phase {
                Text("It will be under Playlists once this device has synced.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Saving")
        }
    }

    /// "Saved: 12 songs here, 6 on their way, 2 not found."
    private static func outcome(_ summary: PlaylistImportSummary) -> String {
        let waiting = summary.asked + summary.already
        var words = "Saved: \(summary.inLibrary ?? 0) of \(summary.tracks) songs in your library"
        if waiting > 0 { words += ", \(waiting) asked for" }
        if summary.unmatched > 0 { words += ", \(summary.unmatched) not found" }
        words += "."
        if summary.state == "failed", let message = summary.message { words += " \(message)" }
        return words
    }
}
