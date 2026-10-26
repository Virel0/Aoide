import Foundation
import os

/// The last thing the sidecar said, kept for when the counts are not enough.
///
/// Three separate faults in this integration have now been diagnosed only after
/// somebody read the server's actual words — an HTTP 500 behind a generic error page,
/// then a 200 acknowledging nothing. In each case the client had the evidence in hand
/// and dropped it on the way to a summary. This is where it stops being dropped.
///
/// Deliberately not persisted. It exists to be read while something is wrong, and a
/// reply can carry the ids of a listener's own rows — it does not belong in a file
/// that outlives the problem.
actor SyncDiagnostics {
    static let shared = SyncDiagnostics()

    struct Exchange: Sendable {
        let at: Date
        let opsSent: Int
        let reply: String
    }

    private(set) var lastPush: Exchange?
    private let log = Logger(subsystem: AppIdentity.bundle, category: "sync")

    /// Truncated: a reply naming every op in a 250-op batch runs long, and the shape
    /// of the first few is what tells you whether it was understood.
    private static let maxReplyLength = 600

    func recordPush(sent: Int, reply: Data) {
        let text = String(decoding: reply.prefix(Self.maxReplyLength), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lastPush = Exchange(at: Date(), opsSent: sent, reply: text.isEmpty ? "(empty body)" : text)
        log.debug("Pushed \(sent, privacy: .public) ops; server replied: \(text, privacy: .public)")
    }
}
