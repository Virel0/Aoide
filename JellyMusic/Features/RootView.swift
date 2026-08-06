import JellyfinKit
import PlaybackKit
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
            if let client = session.client {
                // Keyed on the user id so signing in as someone else builds a fresh
                // store rather than showing the previous account's cached library.
                MainTabView(client: client)
                    .id(client.credentials?.userId)
                    .environment(session)
            } else {
                ProgressView()
            }
        }
    }
}

struct MainTabView: View {
    @State private var store: LibraryStore
    @State private var lyrics: LyricsStore
    @State private var isShowingNowPlaying = false
    @State private var engine = PlaybackEngine.shared

    init(client: JellyfinClient) {
        _store = State(initialValue: LibraryStore(client: client))
        _lyrics = State(initialValue: LyricsStore(client: client))
    }

    var body: some View {
        TabView {
            Tab("Library", systemImage: "music.note.list") {
                LibraryView()
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchView()
            }
        }
        // iOS 26's bottom accessory slot — the same one Apple Music's mini player
        // lives in, so it picks up the glass material and collapse behaviour rather
        // than us faking a bar on top of the tab bar.
        .tabViewBottomAccessory {
            MiniPlayerView(isShowingNowPlaying: $isShowingNowPlaying)
        }
        .environment(store)
        .environment(lyrics)
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
        }
    }
}
