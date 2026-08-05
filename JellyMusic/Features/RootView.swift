import SwiftUI

struct RootView: View {
    @State private var session = AppSession.shared

    var body: some View {
        switch session.state {
        case .loading:
            ProgressView()
        case .signedOut:
            LoginView()
        case .signedIn:
            LibraryPlaceholderView()
        }
    }
}

/// Stands in until the real tabbed library lands. Kept deliberately plain so it's
/// obvious this is scaffolding, not a design decision.
struct LibraryPlaceholderView: View {
    @State private var session = AppSession.shared

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Signed in", systemImage: "checkmark.circle")
            } description: {
                if case .signedIn(let user) = session.state {
                    Text("Connected as \(user.name). The library UI is next.")
                }
            } actions: {
                Button("Sign Out", role: .destructive) {
                    Task { await session.signOut() }
                }
            }
            .navigationTitle("JellyMusic")
        }
    }
}
