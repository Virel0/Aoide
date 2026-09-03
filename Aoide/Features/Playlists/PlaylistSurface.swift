import SwiftUI

/// Which playlists the Playlists screen shows.
///
/// The app has two kinds: the ones kept on this device and synced between Aoide
/// clients, and the ones that live on the Jellyfin server. Somebody who has copied
/// everything across uses only the first kind, and a second section of the same
/// names underneath reads as clutter at best and as duplicates at worst. The other
/// kind is never gone — just not on the page unless asked for.
enum PlaylistSurface: String, CaseIterable, Identifiable {
    /// Both sections, which is how the screen has always looked.
    case both
    /// Only the playlists kept on this device.
    case aoide
    /// Only the playlists on the server.
    case jellyfin

    /// Shared with the desktop app, which keeps the same preference under the same
    /// three values so the two agree about what a person wants to see.
    static let key = "aoide.playlistSurface"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .both: "Both"
        case .aoide: "Mine"
        case .jellyfin: "Server"
        }
    }

    var showsLocal: Bool { self != .jellyfin }
    var showsServer: Bool { self != .aoide }
}
