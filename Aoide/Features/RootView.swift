import CoreSpotlight
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
        } else if ProcessInfo.processInfo.arguments.contains("-AoideTabPreview"),
                  let url = try? JellyfinClient.normalizeServerURL("preview.invalid") {
            // The tab bar itself, without a login. Every screen inside will fail to
            // load — that's fine and beside the point: this exists to check the bar's
            // own layout, which is otherwise unreachable without signing in.
            MainTabView(client: JellyfinClient(serverURL: url, device: AppSession.deviceProfile))
                .environment(AppSession.shared)
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
    private enum TabID: Hashable { case home, library, downloads, search }

    private let client: JellyfinClient
    @State private var store: LibraryStore
    @State private var lyrics: LyricsStore
    @State private var smartSearch: SmartSearch
    @State private var isShowingNowPlaying = false
    @State private var engine = PlaybackEngine.shared
    @State private var selectedTab: TabID = .home
    /// Held here, not inside `LibraryView`, so a Spotlight result can push onto a
    /// tab that has never appeared.
    @State private var libraryPath = NavigationPath()

    init(client: JellyfinClient) {
        self.client = client
        _store = State(initialValue: LibraryStore(client: client))
        _lyrics = State(initialValue: LyricsStore(client: client))
        _smartSearch = State(initialValue: SmartSearch(client: client))
    }

    var body: some View {
        // Four tabs, not Apple Music's five. New and Radio exist because Apple has
        // a catalogue and an editorial staff; against a personal library they would
        // be two permanently empty screens. Downloads earns its place instead —
        // it's the one screen that still works with no signal, which is no use
        // buried a tap inside a Library list that can't load.
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: "house", value: TabID.home) {
                HomeView()
            }
            Tab("Library", systemImage: "music.note.list", value: TabID.library) {
                LibraryView(path: $libraryPath)
            }
            // `arrow.down.circle` is the download glyph everywhere else in the app,
            // but a tab bar substitutes the filled variant and it renders as a
            // solid white disc next to two outline neighbours. This one has no
            // fill to substitute.
            Tab("Downloads", systemImage: "arrow.down.to.line", value: TabID.downloads) {
                NavigationStack { DownloadedView() }
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabID.search, role: .search) {
                SearchView()
            }
        }
        .task { await openToDownloadsIfOffline() }
        .task { CurationDatabase.open() }
        .task { await SpotlightIndexer.shared.indexIfNeeded(client: client) }
        .task {
            // Joining needs no button: when someone else on the call starts a
            // session, this picks it up and adopts what they're playing.
            SharePlayCoordinator.shared.connect(client: client)
            SharePlayCoordinator.shared.listenForSessions()
        }
        // Spotlight hands back the identifier it was given at index time and
        // nothing else, so the destination resolves it into a real item itself.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            selectedTab = .library
            libraryPath.append(LibraryRoute.item(id: id))
        }
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
        .environment(smartSearch)
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
        selectedTab = .downloads
    }
}
