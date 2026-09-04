import CurationKit
import SwiftUI

/// The changes that will never sync, and why.
///
/// This screen exists because quarantine is silent by design. An op reaches it only
/// when retrying is known to be pointless, so nothing ever tries again and nothing
/// ever fails again — which means without somewhere to look, a change that was made
/// and lost looks exactly like a change that synced. That is the one sync failure
/// worth a listener's attention, and it is the only one this app surfaces.
struct SyncQuarantineView: View {
    @State private var ops: [QuarantinedOp] = []
    private var retryable: Int { ops.count(where: \.isRetryable) }
    @State private var isConfirmingDiscardAll = false

    var body: some View {
        List {
            retrySection
            if ops.isEmpty {
                Section {
                    Text("Everything has synced.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(ops, id: \.opId) { op in
                        row(op)
                    }
                    .onDelete(perform: discard)
                } footer: {
                    Text("These were made on a device but the server wouldn't take them, or arrived from a device running a newer version of Aoide. They're kept here rather than retried, because retrying them can't work.")
                }

                Section {
                    Button("Discard All", role: .destructive) {
                        isConfirmingDiscardAll = true
                    }
                } footer: {
                    Text("Discarding forgets the record. It doesn't undo anything — the change is already applied on the device that made it.")
                }
            }
        }
        .navigationTitle("Not Syncing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().disabled(ops.isEmpty) }
        .task { await reload() }
        .confirmationDialog(
            "Discard all \(ops.count) records?",
            isPresented: $isConfirmingDiscardAll,
            titleVisibility: .visible
        ) {
            Button("Discard All", role: .destructive) { discardAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Offered only when something here is worth retrying.
    ///
    /// Every other reason in this list is a statement about the change itself, which
    /// retrying cannot alter. A 5xx is a statement about the server, and servers get
    /// fixed — so this button appears exactly when the thing that went wrong might
    /// have stopped being wrong.
    @ViewBuilder
    private var retrySection: some View {
        if retryable > 0 {
            Section {
                Button {
                    retry()
                } label: {
                    Label(
                        "Try \(retryable) Again",
                        systemImage: "arrow.clockwise"
                    )
                }
            } footer: {
                Text("These failed because your server had a problem, not because anything is wrong with them. If it's been fixed, they'll go through.")
            }
        }
    }

    private func retry() {
        Task {
            guard let store = CurationDatabase.shared else { return }
            _ = await Task.detached { try? store.requeueQuarantined() }.value
            await reload()
            SyncCoordinator.shared.syncNow()
        }
    }

    private func row(_ op: QuarantinedOp) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.title(for: op))
                .font(.body)
            Text(op.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Date(millis: op.quarantinedAt).formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Words

    /// Spelled from the direction and the entity, because the two together are what
    /// tells someone whether *their* change was lost or somebody else's arrived.
    private static func title(for op: QuarantinedOp) -> String {
        let noun = Self.noun(for: op.entity)
        return switch op.syncDirection {
        case .outbound: "A \(noun) change from this device"
        case .inbound: "A \(noun) change from another device"
        case nil: "A \(noun) change"
        }
    }

    /// Accepts both spellings on purpose: an outbound op is stored under the local
    /// table name and an inbound one under the wire name, and quarantine keeps
    /// whichever arrived — for the case this table exists to explain, the unrecognised
    /// spelling is the finding.
    private static func noun(for entity: String) -> String {
        let known = SyncEntity(localTable: entity) ?? SyncEntity(wireName: entity)
        return switch known {
        case .playlist: "playlist"
        case .playlistItem: "playlist track"
        case .folder: "folder"
        case .like: "favourite"
        case .playEvent: "listening history"
        case .queueState: "queue"
        case .trackFlags: "taste flag"
        case nil: "\u{201C}\(entity)\u{201D}"
        }
    }

    // MARK: - Store

    /// Detached, because this is up to 200 rows each carrying a whole op payload and the
    /// store is a serial `DatabaseQueue`: read on the main actor it waits out whatever
    /// transaction is in flight, and a pulled batch holds that queue for up to 500 ops.
    /// Opening this screen during the first sync is exactly when someone would.
    private func reload() async {
        guard let store = CurationDatabase.shared else { return }
        ops = await Task.detached { (try? store.quarantinedOps()) ?? [] }.value
        // Discarding is the one thing that changes the count without a sync, so the
        // badge behind this screen has to be told.
        SyncCoordinator.shared.refreshStatus()
    }

    private func discard(_ offsets: IndexSet) {
        guard let store = CurationDatabase.shared else { return }
        let doomed = offsets.map { ops[$0].opId }
        Task {
            await Task.detached { try? store.discardQuarantined(doomed) }.value
            await reload()
        }
    }

    private func discardAll() {
        guard let store = CurationDatabase.shared else { return }
        Task {
            await Task.detached { try? store.discardAllQuarantined() }.value
            await reload()
        }
    }
}

private extension Date {
    init(millis: Int64) {
        self.init(timeIntervalSince1970: Double(millis) / 1000)
    }
}
