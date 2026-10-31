import Foundation

/// What's playing in a listening-together session, as a device sets it.
public struct ListenState: Encodable, Equatable, Sendable {
    /// Track ids, in order.
    public var queue: [Int64]
    /// Which entry of the queue plays, from 0 (0 for an empty queue).
    public var index: Int
    /// How far into it, in milliseconds, now.
    public var positionMs: Int64
    public var playing: Bool

    public init(queue: [Int64], index: Int, positionMs: Int64, playing: Bool) {
        self.queue = queue
        self.index = index
        self.positionMs = positionMs
        self.playing = playing
    }
}

/// A session several devices play in step, as Melete last told it. Each device
/// plays its own stream; the server raises `version` with every change, and a
/// change made against an older one is refused (``MeleteError/isStale``).
public struct ListenSession: Decodable, Equatable, Sendable {
    public let id: Int64
    /// Six letters and digits others join with.
    public let code: String
    /// The user name of whoever started it.
    public let host: String
    public let queue: [Int64]
    public let index: Int
    /// Where in the track at `positionAt`.
    public let positionMs: Int64
    /// Server time, Unix milliseconds.
    public let positionAt: Int64
    public let playing: Bool
    public let version: Int64
    public let members: [ListenMember]

    /// Where the track is at server time `serverNow`: it moves on from
    /// `positionAt` while playing, and never back.
    public func position(at serverNow: Int64) -> Int64 {
        playing ? positionMs + max(0, serverNow - positionAt) : positionMs
    }
}

/// One device in a session.
public struct ListenMember: Decodable, Equatable, Sendable {
    public let username: String
    /// The device's name, as signed in.
    public let device: String
    /// The device asking.
    public let you: Bool
}

/// A session with the server's clock when it answered, to set this device's by.
public struct Listening: Decodable, Equatable, Sendable {
    public let session: ListenSession
    /// Unix milliseconds.
    public let serverTime: Int64
}

/// The player as it stands, in the queue's own ids.
public struct ListenLocal: Equatable, Sendable {
    public var ids: [String]
    public var index: Int
    public var positionMs: Int64
    public var playing: Bool

    public init(ids: [String], index: Int, positionMs: Int64, playing: Bool) {
        self.ids = ids
        self.index = index
        self.positionMs = positionMs
        self.playing = playing
    }

    /// What to send for it; nil when an id isn't one of Melete's (numbers).
    public var state: ListenState? {
        var queue: [Int64] = []
        for id in ids {
            guard let number = Int64(id) else { return nil }
            queue.append(number)
        }
        return ListenState(queue: queue, index: index, positionMs: positionMs, playing: playing)
    }
}

/// What playing in step with a session takes.
public enum ListenPlan: Equatable, Sendable {
    /// Already there.
    case nothing
    /// A different queue: load the session's.
    case rebuild
    /// The same queue: play another entry, go to a place, play or pause.
    case adjust(jump: Int?, seek: Int64?, play: Bool?)

    /// How far a player may be from the session before it counts as elsewhere:
    /// enough for a stream that took a moment to start, short of a skip anyone
    /// would hear.
    public static let toleranceMs: Int64 = 3_000

    /// What brings `local` to where `session` is at server time `serverNow`.
    public init(session: ListenSession, local: ListenLocal, serverNow: Int64) {
        guard session.queue.map(String.init) == local.ids else {
            self = .rebuild
            return
        }
        guard !session.queue.isEmpty else {
            self = .nothing
            return
        }
        let expected = session.position(at: serverNow)
        let jump = session.index == local.index ? nil : session.index
        let seek = jump != nil || abs(expected - local.positionMs) > Self.toleranceMs ? expected : nil
        let play = session.playing == local.playing ? nil : session.playing
        self = jump == nil && seek == nil && play == nil ? .nothing : .adjust(jump: jump, seek: seek, play: play)
    }
}
