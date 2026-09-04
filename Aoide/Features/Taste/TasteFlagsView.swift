import CurationKit
import SwiftUI

/// Every track the listener has flagged, so a flag can be found and undone.
///
/// Reachable from Settings rather than from the tracks themselves, because the
/// whole point of "not interested" is that the track stops turning up — which
/// would otherwise make the flag impossible to find again.
struct TasteFlagsView: View {
    @State private var taste = TasteStore.shared

    var body: some View {
        List {
            if taste.flagged.isEmpty {
                ContentUnavailableView {
                    Label("Nothing Flagged", systemImage: "hand.thumbsdown")
                } description: {
                    Text("Long-press a song and choose Not Interested or Don't Count Plays. It'll be listed here so you can undo it.")
                }
            } else {
                ForEach(taste.flagged, id: \.flags.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.track?.title ?? entry.flags.jellyfinId)
                            .lineLimit(1)
                        Text(detail(entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .swipeActions {
                        Button("Clear") { Task { await taste.clear(entry.flags) } }
                            .tint(.accentColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Hidden from Mixes")
        .task { await taste.reloadFlagged() }
    }

    private func detail(_ entry: (flags: TrackFlags, track: TrackRef?)) -> String {
        var parts: [String] = []
        if let artist = entry.track?.artist, !artist.isEmpty { parts.append(artist) }
        if entry.flags.notInterested { parts.append("Not interested") }
        if entry.flags.dontCount { parts.append("Plays not counted") }
        return parts.joined(separator: " · ")
    }
}
