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
    /// Only fetched while a failure is on screen: it is a debugging aid, not a
    /// permanent part of Settings.
    @State private var lastReply: SyncDiagnostics.Exchange?
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

            // Shown only when something is wrong, and it is the server's own words
            // rather than a summary of them. Three faults in this integration have
            // now been diagnosed only after somebody read the actual reply — the
            // summary is what hid the cause each time.
            if let reply = lastReply {
                NavigationLink {
                    ServerReplyView(reply: reply)
                } label: {
                    LabeledContent("Server's Last Reply", value: "View")
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
        // Fetched only while a failure is showing. Keyed on the failure itself so it
        // refreshes when the fault changes and clears when it goes away, rather than
        // leaving a stale reply behind describing a problem that is over.
        .task(id: sync.failure) {
            lastReply = sync.failure == nil ? nil : await SyncDiagnostics.shared.lastPush
        }
    }

    /// Says what is happening when something is, and what the feature is for when
    /// nothing is. A failure lands here and nowhere else — never an alert, never over
    /// the top of playing music.
    private var footer: String {
        if let detail = sync.statusDetail { return detail }
        return """
            Playlists, favourites and listening history sync between your devices \
            through your Melete server. It happens by itself when you open the app and \
            after you make changes \u{2014} this button is only for when you don't want \
            to wait.
            """
    }
}

/// The sidecar's last answer, verbatim.
///
/// Selectable rather than merely displayed: the point of this screen is that somebody
/// can copy what the server said into wherever the server is being fixed.
private struct ServerReplyView: View {
    let reply: SyncDiagnostics.Exchange

    var body: some View {
        List {
            Section {
                LabeledContent("Changes Sent", value: "\(reply.opsSent)")
                LabeledContent("At", value: reply.at.formatted(date: .omitted, time: .standard))
            }
            Section {
                Text(reply.reply)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("What Your Server Replied")
            } footer: {
                Text("Copy this if you're working out why sync is stuck — it's the server's own answer, not this app's summary of it.")
            }
        }
        .navigationTitle("Server's Last Reply")
        .navigationBarTitleDisplayMode(.inline)
    }
}
