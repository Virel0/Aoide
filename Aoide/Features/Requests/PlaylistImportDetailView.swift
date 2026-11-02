import MeleteKit
import SwiftUI

/// One playlist asked for song by song: its tally, what became of each song, and
/// Remove, which takes back the songs still waiting for approval.
struct PlaylistImportDetailView: View {
    let summary: PlaylistImportSummary
    /// Called once it's removed, so the list can read itself again.
    let onRemoved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var read: PlaylistImport?
    @State private var errorMessage: String?
    @State private var isConfirmingRemove = false
    @State private var isRemoving = false

    private var current: PlaylistImportSummary { read?.summary ?? summary }

    var body: some View {
        List {
            Section {
                Text(current.tally)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let read {
                Section("Songs") {
                    ForEach(read.items) { track in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(track.position). \(track.title)")
                            Text(([track.artist, track.standing] as [String?]).compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .overlay {
            if read == nil {
                if let errorMessage {
                    ErrorRow(message: errorMessage) { Task { await load() } }
                } else {
                    ProgressView()
                }
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle(summary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Remove", role: .destructive) { isConfirmingRemove = true }
                    .disabled(isRemoving)
            }
        }
        .confirmationDialog("Remove \(summary.name)?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Its songs still waiting for approval are taken back. Approved ones still come.")
        }
        .refreshable { await load() }
        .task(id: current.isRunning) {
            await load()
            // While it's still asking, how far it has got.
            while current.isRunning, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await load()
            }
        }
    }

    private func load() async {
        guard let client = AppSession.shared.client else { return }
        do {
            read = try await client.playlistImport(id: summary.id)
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func remove() async {
        guard let client = AppSession.shared.client else { return }
        isRemoving = true
        defer { isRemoving = false }
        do {
            try await client.removePlaylistImport(id: summary.id)
            await onRemoved()
            dismiss()
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }
}
