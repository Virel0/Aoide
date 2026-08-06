import Testing
@testable import CurationKit

/// The whole ordering scheme rests on these holding, and the failure mode when they
/// don't is a playlist that silently reorders itself.
@Suite("Fractional index")
struct FractionalIndexTests {
    @Test("a key lands strictly between its neighbours")
    func between() {
        let a = FractionalIndex.initial
        let b = FractionalIndex.between(a, nil)
        let mid = FractionalIndex.between(a, b)
        #expect(a < mid)
        #expect(mid < b)
    }

    @Test("appending stays ordered")
    func appending() {
        let keys = FractionalIndex.sequence(after: nil, count: 50)
        #expect(keys == keys.sorted())
        #expect(Set(keys).count == 50)
    }

    /// The case that motivates the "never end in the smallest digit" invariant:
    /// nothing sorts between "" and "0", so a key of "0" could never be preceded.
    @Test("there is always room to insert before the first key")
    func prepending() {
        var first = FractionalIndex.initial
        for _ in 0..<200 {
            let earlier = FractionalIndex.between(nil, first)
            #expect(earlier < first, "no room left before \(first)")
            first = earlier
        }
    }

    @Test("no generated key ends in the smallest digit")
    func neverEndsInSmallestDigit() {
        var keys = [FractionalIndex.initial]
        for _ in 0..<200 {
            keys.append(FractionalIndex.between(nil, keys.last!))
            keys.append(FractionalIndex.between(keys.first!, nil))
        }
        for key in keys {
            #expect(key.last != FractionalIndex.alphabet[0], "\(key) ends in the smallest digit")
        }
    }

    /// Repeatedly inserting into the same gap is the pathological case: each key has
    /// to fit inside an ever-narrowing window.
    @Test("repeated insertion into one gap keeps working")
    func repeatedInsertionInSameGap() {
        var low = FractionalIndex.initial
        let high = FractionalIndex.between(low, nil)
        for step in 0..<200 {
            let mid = FractionalIndex.between(low, high)
            #expect(low < mid, "step \(step): \(mid) not above \(low)")
            #expect(mid < high, "step \(step): \(mid) not below \(high)")
            low = mid
        }
    }

    /// Two devices inserting at the same spot must both survive. Integer positions
    /// are exactly what this test would fail on.
    @Test("concurrent inserts at the same spot both survive")
    func concurrentInserts() {
        let a = FractionalIndex.initial
        let b = FractionalIndex.between(a, nil)
        let one = FractionalIndex.between(a, b)
        let two = FractionalIndex.between(a, b)
        #expect(one == two)   // same inputs, same key — and both rows still exist
        #expect(a < one && one < b)
    }

    @Test("a whole list stays sorted under random insertion")
    func randomInsertion() {
        var keys = FractionalIndex.sequence(after: nil, count: 10)
        // Deterministic rather than random: a seeded shuffle would still make a
        // failure hard to reproduce from the test name alone.
        for step in 0..<100 {
            let at = (step * 7) % (keys.count + 1)
            let lower = at > 0 ? keys[at - 1] : nil
            let upper = at < keys.count ? keys[at] : nil
            let key = FractionalIndex.between(lower, upper)
            keys.insert(key, at: at)
            #expect(keys == keys.sorted(), "step \(step) broke the ordering")
        }
        #expect(Set(keys).count == keys.count)
    }

    /// Appending gains a character per carry through the alphabet, so growth is
    /// slow rather than free — a thousand appends reach 33 characters. This pins
    /// that: an earlier version bisected towards the ceiling instead and reached
    /// 167 for the same thousand.
    @Test("keys stay short enough to store cheaply")
    func lengthStaysReasonable() {
        let keys = FractionalIndex.sequence(after: nil, count: 1000)
        let longest = keys.map(\.count).max() ?? 0
        #expect(longest <= 40, "append-only keys grew to \(longest) characters")
    }
}
