import Foundation
import Testing
@testable import PlaybackKit

/// The retry schedule decides whether a dead spot on a walk costs a track or a few
/// seconds. Pinned so a "small" tweak cannot quietly turn it back into a skip.
@Suite("Load retry policy")
struct LoadRetryPolicyTests {
    @Test("the current track gets every delay, then is given up on")
    func currentTrackGivesUp() {
        let delays = (1...LoadRetryPolicy.delays.count).map {
            LoadRetryPolicy.delay(afterFailures: $0, whileQueued: false)
        }
        #expect(delays == LoadRetryPolicy.delays)
        #expect(LoadRetryPolicy.delay(afterFailures: LoadRetryPolicy.delays.count + 1, whileQueued: false) == nil)
    }

    @Test("a queued track keeps retrying at the longest delay forever")
    func queuedNeverGivesUp() {
        let beyond = LoadRetryPolicy.delays.count + 1
        #expect(LoadRetryPolicy.delay(afterFailures: beyond, whileQueued: true) == LoadRetryPolicy.delays.last)
        #expect(LoadRetryPolicy.delay(afterFailures: beyond * 10, whileQueued: true) == LoadRetryPolicy.delays.last)
    }

    @Test("delays grow, and the first retry is quick")
    func delaysGrow() {
        let delays = LoadRetryPolicy.delays
        #expect(delays.first.map { $0 <= .seconds(3) } == true)
        #expect(zip(delays, delays.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("the current track is abandoned after about half a minute, not after a first stumble")
    func totalPatience() {
        let total = LoadRetryPolicy.delays.reduce(Duration.zero, +)
        #expect(total >= .seconds(20))
        #expect(total <= .seconds(45))
    }
}
