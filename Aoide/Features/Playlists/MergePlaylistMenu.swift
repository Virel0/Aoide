import CurationKit
import SwiftUI

/// A merge that has just happened, kept so the listener can decide about the original.
struct MergeOutcome: Identifiable {
    let source: Playlist
    let target: Playlist
    let report: MergeReport

    var id: String { source.id + target.id }

    var title: String {
        let songs = report.total == 1 ? "1 song" : "\(report.total) songs"
        return report.total == 0
            ? "“\(target.name)” already has every song"
            : "Added \(songs) to “\(target.name)”"
    }
}

/// "Merge into" for a playlist's menus: every playlist of the listener's that can take
/// songs, except the one being merged. Smart playlists are left out, since their songs
/// come from their rules.
struct MergePlaylistMenu: View {
    @Environment(LocalPlaylistStore.self) private var playlists
    let source: Playlist
    let merged: (MergeOutcome) -> Void

    private var targets: [Playlist] {
        playlists.playlists.filter { !$0.isSmart && $0.id != source.id }
    }

    var body: some View {
        if !targets.isEmpty {
            Menu("Merge into", systemImage: "arrow.triangle.merge") {
                ForEach(targets, id: \.id) { target in
                    Button(target.name) {
                        Task {
                            guard let report = await playlists.merge(source, into: target) else { return }
                            merged(MergeOutcome(source: source, target: target, report: report))
                        }
                    }
                }
            }
        }
    }
}

extension View {
    /// Asks, after a merge, whether the original should go. Keeping it is the default
    /// and the cancel button, so nothing is deleted without a deliberate tap.
    func mergeOutcomeDialog(_ outcome: Binding<MergeOutcome?>, delete: @escaping (Playlist) -> Void) -> some View {
        confirmationDialog(
            outcome.wrappedValue?.title ?? "",
            isPresented: Binding(get: { outcome.wrappedValue != nil }, set: { if !$0 { outcome.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: outcome.wrappedValue
        ) { done in
            Button("Delete “\(done.source.name)”", role: .destructive) { delete(done.source) }
            Button("Keep Both", role: .cancel) {}
        } message: { done in
            Text(Self.message(for: done))
        }
    }

    private static func message(for done: MergeOutcome) -> String {
        var lines = [
            done.source.isSmart
                ? "“\(done.target.name)” has the songs “\(done.source.name)” matches today. Deleting “\(done.source.name)” removes its rules."
                : "Its songs are all in “\(done.target.name)” now, so “\(done.source.name)” can go.",
        ]
        if done.report.waiting > 0 {
            let songs = done.report.waiting == 1 ? "1 song is" : "\(done.report.waiting) songs are"
            lines.append("\(songs) still waiting to arrive.")
        }
        return lines.joined(separator: " ")
    }
}
