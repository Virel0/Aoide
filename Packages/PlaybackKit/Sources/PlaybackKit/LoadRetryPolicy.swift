import Foundation

/// What to do when a track's stream fails to load.
///
/// Walking between buildings, a stream that fails is almost never a bad track: it
/// is a phone that had no signal for the few seconds the player happened to ask.
/// Dropping the track on the first failure — which is what happened before — read
/// as the app skipping songs for no reason. Giving up is still necessary, or a
/// genuinely broken file would freeze the queue on it forever; the point is to give
/// up *slowly*, after roughly the length of a dead spot.
enum LoadRetryPolicy {
    /// Waits before each retry. Doubling, so a brief outage costs seconds and a
    /// long one costs few requests. Sums to thirty seconds, about a tunnel.
    static let delays: [Duration] = [.seconds(2), .seconds(4), .seconds(8), .seconds(16)]

    /// How long to wait before trying again after `failures` consecutive failures,
    /// or nil to give up.
    ///
    /// A track that is *queued* behind something that is playing never gives up:
    /// nothing is lost by retrying every sixteen seconds until it becomes current,
    /// and the alternative is silently skipping it when the music reaches it. The
    /// *current* track has the listener waiting on it, so after the delays run out
    /// it is abandoned and the queue moves on.
    static func delay(afterFailures failures: Int, whileQueued queued: Bool) -> Duration? {
        precondition(failures >= 1, "asked for a retry delay with no failure")
        if failures <= delays.count { return delays[failures - 1] }
        return queued ? delays.last : nil
    }
}
