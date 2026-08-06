import SwiftUI

/// The Sync section of Settings — the only place sync is visible at all.
///
/// Three numbers, chosen because each answers a question somebody would otherwise
/// have no way to ask. *When* it last worked says whether the other device's changes
/// should be here yet. *How many are waiting* says whether this device has anything
/// the server has not taken. And *how many are not syncing* is the one that would
/// otherwise be invisible: quarantined ops are never retried, so nothing fails twice
/// and a lost change looks identical to a synced one.
///
/// A section rather than its own screen. Sync working is not an achievement worth a
/// destination, and burying the quarantine count one tap deeper would defeat the
/// point of showing it.
struct SyncSection: View {
    @State private var sync = SyncCoordinator.shared

    var body: some View {
        Section {
            LabeledContent("Last Sync", value: sync.lastSuccessSummary)
            LabeledContent("Waiting to Send", value: sync.pendingSummary)

            // Absent at zero, which is where it should be. This row appearing is the
            // entire notification mechanism for a failure the app otherwise swallows.
            if sync.quarantined > 0 {
                NavigationLink {
                    SyncQuarantineView()
                } label: {
                    LabeledContent {
                        Text("\(sync.quarantined)")
                    } label: {
                        HStack(spacing: 6) {
                            // Only the symbol is coloured. Tinting the whole row would
                            // read as an error state for the section rather than a
                            // pointer at one row inside it.
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Not Syncing")
                        }
                    }
                }
            }

            Button {
                sync.syncNow()
            } label: {
                HStack {
                    Text("Sync Now")
                    if sync.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(sync.isSyncing || !sync.isAvailable)
        } header: {
            Text("Sync")
        } footer: {
            Text(footer)
        }
    }

    /// Says what is happening when something is, and what the feature is for when
    /// nothing is. A failure lands here and nowhere else — never an alert, never over
    /// the top of playing music.
    private var footer: String {
        if let detail = sync.statusDetail { return detail }
        return "Playlists, favourites and listening history sync between your devices through your Jellyfin server. It happens by itself when you open the app and after you make changes \u{2014} this button is only for when you don't want to wait."
    }
}
