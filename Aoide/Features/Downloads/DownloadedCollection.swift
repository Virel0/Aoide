import Foundation

/// An album or playlist somebody downloaded *as a whole*.
///
/// The download store only knows about files, one per track. That is the right
/// unit for transfers and the wrong one for a screen: somebody who downloaded three
/// albums and a playlist thinks of four things, not sixty. This remembers the four,
/// so the Downloads screen can show them as such and keep the individual songs for
/// the songs that were downloaded individually.
struct DownloadedCollection: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case album
        case playlist
    }

    /// The Jellyfin album id, or the local playlist's id — whichever it came from.
    let id: String
    let kind: Kind
    var name: String
    /// The album artist. Playlists have none.
    var subtitle: String?
    /// In the collection's own order, which is what plays when it is tapped.
    var trackIds: [String]
}
