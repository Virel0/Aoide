import JellyfinKit
import SwiftUI

/// The two taste toggles, for any track context menu.
///
/// Worded as what they do rather than as flags: a menu that says "Not Interested"
/// is understood; one that says "notInterested: true" is a database.
struct TasteFlagButtons: View {
    let track: JellyfinItem
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
