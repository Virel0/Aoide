import MeleteKit
import SwiftUI

/// Music this listener has asked Melete for, newest first, with where each stands
/// (waiting, declined and why, or how its download is going, kept up to date
/// while the screen is open) and Withdraw for one still waiting; then the
/// playlists asked for song by song. Asking happens in Search and Import.
struct RequestsView: View {
    @State private var requests: [MusicRequest] = []
    @State private var imports: [PlaylistImportSummary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            ForEach(requests) { request in
                RequestRow(request: request)
                    .swipeActions {
                        if request.state == .requested {
                            Button("Withdraw", role: .destructive) {
                                Task { await withdraw(request) }
                            }
                        }
                    }
            }
            if !imports.isEmpty {
                Section("Playlists") {
                    ForEach(imports) { summary in
                        NavigationLink {
                            PlaylistImportDetailView(summary: summary) { await load() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.name)
                                Text(summary.tally)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if isLoading && requests.isEmpty {
                ProgressView()
            } else if let errorMessage {
                ErrorRow(message: errorMessage) { Task { await load() } }
            } else if requests.isEmpty && imports.isEmpty {
                ContentUnavailableView(
                    "Nothing Asked For",
                    systemImage: "plus.magnifyingglass",
                    description: Text("Search for an album, artist or song that isn't in your library, then ask for it.")
                )
            }
        }
        .miniPlayerInset()
        .appBackground()
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .task { await follow() }
        .task(id: imports.contains(where: \.isRunning)) { await followImports() }
    }

    private func load() async {
        guard let client = AppSession.shared.client else { return }
        isLoading = true
        errorMessage = nil
        do {
            requests = try await client.musicRequests()
        } catch {
            errorMessage = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
        // A server without imports still lists its requests.
        imports = (try? await client.playlistImports()) ?? imports
        isLoading = false
    }

    /// Melete's request feed while the screen is open, opened again when it ends.
    private func follow() async {
        guard let client = AppSession.shared.client else { return }
        while !Task.isCancelled {
            do {
                try await client.followRequests { live in
                    requests = MusicRequest.merging(live, over: requests)
                }
            } catch is CancellationError {
                return
            } catch MeleteError.unauthorized {
                return
            } catch {
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// While a playlist is still being asked for, its tally every few seconds.
    private func followImports() async {
        guard let client = AppSession.shared.client else { return }
        while imports.contains(where: \.isRunning), !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            imports = (try? await client.playlistImports()) ?? imports
        }
    }

    private func withdraw(_ request: MusicRequest) async {
        guard let client = AppSession.shared.client else { return }
        problem = nil
        do {
            try await client.withdrawRequest(id: request.id)
        } catch {
            problem = "Couldn't withdraw \(request.title): it may have been decided already."
        }
        await load()
    }
}

/// One request: what it is, where it stands, and the finer points.
private struct RequestRow: View {
    let request: MusicRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.title)
            Text(([request.kind.word, request.artist, request.year.map(String.init)] as [String?])
                .compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(request.standing)
                .font(.footnote)
                .foregroundStyle(.tint)
            // Once a minute, so "2 minutes ago" stays true.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let detail = request.detail(now: context.date) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
