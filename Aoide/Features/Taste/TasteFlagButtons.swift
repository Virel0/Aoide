import MeleteKit
import PlaybackKit
import SwiftUI

/// The two taste toggles, for any track context menu.
///
/// Worded as what they do rather than as flags: a menu that says "Not Interested"
/// is understood; one that says "notInterested: true" is a database.
struct TasteFlagButtons: View {
    let track: MusicItem
    @State private var taste = TasteStore.shared

    var body: some View {
        let notInterested = taste.isNotInterested(track.id)
        let dontCount = taste.isDontCount(track.id)

        Button(
            notInterested ? "Offer This Again" : "Not Interested",
            systemImage: notInterested ? "hand.thumbsup" : "hand.thumbsdown"
        ) {
            Task { await taste.setNotInterested(!notInterested, on: track) }
        }
        Button(
            dontCount ? "Count Plays" : "Don't Count Plays",
            systemImage: dontCount ? "chart.bar" : "chart.bar.xaxis"
        ) {
            Task { await taste.setDontCount(!dontCount, on: track) }
        }
    }
}

/// The same two toggles for a track the player holds rather than a library
/// row — the one playing, or one in the queue.
///
/// The player's `Track` is not the library's `MusicItem`, and a flag is
/// written against the item (its content key is built from the item's own
/// fields, the same way on every device). So the item is fetched when the
/// button is pressed, the way CarPlay does it; the label reads the flag by id
/// and needs nothing fetched.
///
/// "Not Interested" on the record playing also skips it: nobody flags a song
/// they want to keep hearing, and Infinity would otherwise leave it running
/// to the end.
struct TrackTasteButtons: View {
    let track: Track
    /// Whether flagging the track as not interested also moves on from it.
    var skips = false
    /// Run after the track is flagged as not interested — a queue row uses
    /// it to take the row away.
    var onNotInterested: (() -> Void)? = nil
    @State private var taste = TasteStore.shared

    var body: some View {
        let notInterested = taste.isNotInterested(track.id)
        let dontCount = taste.isDontCount(track.id)

        Button(
            notInterested ? "Offer This Again" : "Not Interested",
            systemImage: notInterested ? "hand.thumbsup" : "hand.thumbsdown"
        ) {
            Task {
                guard let item = await resolve() else { return }
                await taste.setNotInterested(!notInterested, on: item)
                if !notInterested {
                    if skips { PlaybackEngine.shared.next() }
                    onNotInterested?()
                }
            }
        }
        Button(
            dontCount ? "Count Plays" : "Don't Count Plays",
            systemImage: dontCount ? "chart.bar" : "chart.bar.xaxis"
        ) {
            Task {
                guard let item = await resolve() else { return }
                await taste.setDontCount(!dontCount, on: item)
            }
        }
    }

    private func resolve() async -> MusicItem? {
        guard let client = AppSession.shared.client else { return nil }
        return try? await client.items(ids: [track.id]).first
    }
}
