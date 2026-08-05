import Foundation

/// Jellyfin counts one nanosecond as 100 ticks.
private let ticksPerSecond: Int64 = 10_000_000

extension Duration {
    var jellyfinTicks: Int64 {
        Int64(Double(components.seconds) * Double(ticksPerSecond))
            + Int64(Double(components.attoseconds) / 1e18 * Double(ticksPerSecond))
    }
}

struct PlaybackStartRequest: Encodable {
    let itemId: String
    let positionTicks: Int64
    let isPaused: Bool
    let canSeek: Bool
    let playMethod: String

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
        case playMethod = "PlayMethod"
    }
}

struct PlaybackProgressRequest: Encodable {
    let itemId: String
    let positionTicks: Int64
    let isPaused: Bool
    let playMethod: String
    let eventName: String

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case positionTicks = "PositionTicks"
        case isPaused = "IsPaused"
        case playMethod = "PlayMethod"
        case eventName = "EventName"
    }
}

struct PlaybackStoppedRequest: Encodable {
    let itemId: String
    let positionTicks: Int64

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case positionTicks = "PositionTicks"
    }
}

extension JellyfinClient {
    /// Reporting playback is what makes play counts, "recently played", and resume
    /// position work — and what stops the server showing a phantom active session
    /// forever after the app is killed.
    ///
    /// `PlayMethod` is reported as `Transcode` because we stream via
    /// `/Audio/{id}/universal` and let the server decide; it knows better than we do
    /// whether it ended up transcoding.
    public func reportPlaybackStarted(itemId: String, position: Duration = .zero) async throws {
        try await postIgnoringResponse(
            path: "Sessions/Playing",
            body: PlaybackStartRequest(
                itemId: itemId,
                positionTicks: position.jellyfinTicks,
                isPaused: false,
                canSeek: true,
                playMethod: "Transcode"
            )
        )
    }

    public func reportPlaybackProgress(itemId: String, position: Duration, isPaused: Bool) async throws {
        try await postIgnoringResponse(
            path: "Sessions/Playing/Progress",
            body: PlaybackProgressRequest(
                itemId: itemId,
                positionTicks: position.jellyfinTicks,
                isPaused: isPaused,
                playMethod: "Transcode",
                eventName: isPaused ? "Pause" : "TimeUpdate"
            )
        )
    }

    public func reportPlaybackStopped(itemId: String, position: Duration) async throws {
        try await postIgnoringResponse(
            path: "Sessions/Playing/Stopped",
            body: PlaybackStoppedRequest(
                itemId: itemId,
                positionTicks: position.jellyfinTicks
            )
        )
    }
}
