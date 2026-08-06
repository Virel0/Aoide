import PlaybackKit
import SwiftUI

/// Light, dark, or follow the system.
///
/// Defaults to dark. A music app spends its life next to album artwork, and a dark
/// ground is what lets covers carry the page — light mode makes the app the loudest
/// thing on screen instead of the record.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: Self { self }

    var displayName: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

// `Color.appBackground` comes from the asset catalogue — Xcode generates the symbol
// from `AppBackground.colorset`. It's deeper than `.systemBackground` in dark so
// artwork reads as the brightest thing on screen, and a hair off white in light so
// cards and covers have an edge to sit against.

/// Gives every scrollable page room for the mini player.
///
/// The mini player lives in the tab bar's accessory slot, which does not extend the
/// safe area of scroll views nested inside a `NavigationStack` — so without this the
/// last row of every list sits permanently behind it and reads as "the page won't
/// scroll any further".
struct MiniPlayerInset: ViewModifier {
    @State private var engine = PlaybackEngine.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if engine.currentTrack != nil {
                Color.clear.frame(height: 54)
            }
        }
    }
}

extension View {
    func miniPlayerInset() -> some View {
        modifier(MiniPlayerInset())
    }

    /// The standard page ground, applied behind scrolling content.
    func appBackground() -> some View {
        background(Color.appBackground)
    }
}
