import MeleteKit
import SwiftUI

/// The listener's collections: songs saved on Melete's web as a filter
/// (genres, years, liked songs), each opening its songs. They're made on the
/// web; here they're played, and deleted.
struct CollectionsView: View {
    @State private var collections: [SongCollection]?
    @State private var errorMessage: String?
    @State private var deleting: SongCollection?

    var body: some View {
        Group {
            if let collections {
                if collections.isEmpty {
                    ContentUnavailableView(
                        "No Collections",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text(
                            "On Melete's web, narrow Songs by genre, years or liked songs and save it as a collection. It shows here."
                        )
                    )
                } else {
                    List(collections) { row($0) }
                        .listStyle(.plain)
                }
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Collections")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "Delete?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { collection in
            Button("Delete Collection", role: .destructive) { Task { await delete(collection) } }
        } message: { _ in
            Text("Its songs stay in your library.")
        }
    }

    private func row(_ collection: SongCollection) -> some View {
        NavigationLink {
            CollectionDetailView(collection: collection)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).lineLimit(1)
                Text(collection.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = collection }
        }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = collection }
        }
    }

    private func load() async {
        guard let client = AppSession.shared.client else { return }
        errorMessage = nil
        do {
            collections = try await client.collections()
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func delete(_ collection: SongCollection) async {
        guard let client = AppSession.shared.client else { return }
        do {
            try await client.deleteCollection(collection.id)
            collections?.removeAll { $0.id == collection.id }
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
            collections = nil
        }
    }
}
