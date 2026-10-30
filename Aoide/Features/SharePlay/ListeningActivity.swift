import Foundation
import GroupActivities

/// Listening together over FaceTime.
///
/// Only the *identity* of what's playing travels — track ids, never audio. Each
/// participant streams from the same Melete server with their own account and
/// token, so nothing is relayed and nobody hears music they don't have access to.
/// That also means this works only between people with accounts on the server,
/// which for a private server is correct behaviour rather than a limitation.
struct ListeningActivity: GroupActivity {
    static let activityIdentifier = AppIdentity.named("listening")

    var albumTitle: String
    var artist: String

    var metadata: GroupActivityMetadata {
        var metadata = GroupActivityMetadata()
        metadata.type = .listenTogether
        metadata.title = albumTitle
        metadata.subtitle = artist
        return metadata
    }
}

/// What one participant tells the others.
///
/// The whole queue, deliberately, not just the current track: someone joining
/// mid-song would otherwise hear that one track and then silence, because the
/// message naming the next one went out before they arrived.
struct QueueMessage: Codable, Sendable {
    var trackIds: [String]
    var startIndex: Int
}
