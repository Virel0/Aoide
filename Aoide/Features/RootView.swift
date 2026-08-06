import JellyfinKit
import PlaybackKit
import SwiftUI

struct RootView: View {
    @State private var session = AppSession.shared
    @AppStorage("aoide.appearance") private var appearance = AppearanceMode.dark

    var body: some View {
        content
            .preferredColorScheme(appearance.colorScheme)
            .tint(.accentColor)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-AoideUIHarness") {
            UIHarness()
        } else {
            signedInContent
        }
        #else
        signedInContent
        #endif
    }

    @ViewBuilder
    private var signedInContent: some View {
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
                    // Asked here rather than at launch: on the login screen it would
                    // be requesting permission for something not yet usable.
                    .task { SiriAuthorization.shared.requestIfNeeded() }
            } else {
                ProgressView()
            }
        }
    }
}

struct MainTabView: View {
    private enum TabID: Hashable { case home, library, search }

    @State private var store: LibraryStore
    @State private var lyrics: LyricsStore
    @State private var isShowingNowPlaying = false
    @State private var engine = PlaybackEngine.shared
    @State private var selectedTab: TabID = .home
    /// Held here rather than inside `LibraryView` so an offline launch can push
    /// Downloaded onto a tab that hasn't been shown yet.
    @State private var libraryPath = NavigationPath()

    init(client: JellyfinClient) {
        _store = State(initialValue: LibraryStore(client: client))
        _lyrics = State(initialValue: LyricsStore(client: client))
    }

    var body: some View {
        // Three tabs, not Apple Music's five. New and Radio exist because Apple has
        // a catalogue and an editorial staff; against a personal library they would
        // be two permanently empty screens.
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: TabID.home) {
                HomeView()
            }
            Tab("Library", systemImage: "music.note.list", value: TabID.library) {
                LibraryView(path: $libraryPath)
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabID.search, role: .search) {
                SearchView()
            }
        }
        .task { await openToDownloadsIfOffline() }
        // iOS 26's bottom accessory slot — the same one Apple Music's mini player
        // lives in, so it picks up the glass material and collapse behaviour rather
        // than us faking a bar on top of the tab bar.
        .tabViewBottomAccessory {
            MiniPlayerView(isShowingNowPlaying: $isShowingNowPlaying)
        }
        .sheet(isPresented: $isShowingNowPlaying) {
            // Injected directly into the sheet as well as inherited below. A sheet
            // is an environment boundary: content presented by a modifier attached
            // *above* an `.environment(_:)` call is hosted in the environment from
            // above it, where the value doesn't exist — and a missing `@Environment`
            // observable is a trap, not a nil.
            NowPlayingView()
                .environment(store)
                .environment(lyrics)
        }
        // Applied last so everything beneath — the tabs, the accessory, and the
        // sheet modifier itself — sees them.
        .environment(store)
        .environment(lyrics)
    }

    /// Opens straight to Downloaded when there's no connection and something is
    /// actually downloaded.
    ///
    /// Both conditions are required. Offline with an empty download folder, the
    /// right screen is still Home — it can at least say what went wrong, whereas an
    /// empty Downloaded list looks like the library was lost.
    private func openToDownloadsIfOffline() async {
        await Reachability.shared.settled()
        guard Reachability.shared.isOnline == false else { return }
        guard DownloadStore.shared.downloadedCount > 0 else { return }
        selectedTab = .library
        libraryPath.append(LibraryRoute.downloaded)
    }
}
