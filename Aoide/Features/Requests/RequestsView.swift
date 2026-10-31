import MeleteKit
import SwiftUI

/// Music this listener has asked Melete for, newest first, with where each stands
/// (waiting, declined and why, or how its download is going) and Withdraw for one
/// still waiting. Asking happens in Search.
struct RequestsView: View {
    @State private var requests: [MusicRequest] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var problem: String?

    var body: some View {
        List {
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.title)
                    Text(([request.kind.word, request.artist, request.year.map(String.init)] as [String?])
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(request.standing)
                        .font(.footnote)
                        .foregroundStyle(.tint)
                }
                .swipeActions {
                    if request.state == .requested {
                        Button("Withdraw", role: .destructive) {
                            Task { await withdraw(request) }
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
            } else if requests.isEmpty {
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
        isLoading = false
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
