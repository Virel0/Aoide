import Foundation

/// Sortable position keys that can be inserted between without renumbering.
///
/// Playlist order is stored as one of these rather than as an integer. With
/// integers, inserting at row 3 rewrites every row below it — so two devices
/// inserting at once produce dozens of conflicting updates, and a last-writer-wins
/// merge silently drops one of the inserts. A fractional key means an insert writes
/// exactly **one** row, and two concurrent inserts at the same spot both survive in
/// some arbitrary relative order rather than one destroying the other.
///
/// Keys are compared as plain strings, so the database can `ORDER BY position` with
/// no special handling.
public enum FractionalIndex {
    /// Ordered so that ASCII string comparison matches digit order. Digits before
    /// uppercase before lowercase is already true in ASCII, which is what lets the
    /// comparison be the ordinary one.
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    static var base: Int { alphabet.count }

    /// A key for the first item in an empty list.
    public static var initial: String { between(nil, nil) }

    /// A key that sorts strictly between `lower` and `upper`.
    ///
    /// `nil` means unbounded: `between(nil, first)` prepends, `between(last, nil)`
    /// appends. Callers must pass `lower < upper`; there is no key between a value
    /// and itself.
    public static func between(_ lower: String?, _ upper: String?) -> String {
        assert(
            !(lower != nil && upper != nil) || lower! < upper!,
            "FractionalIndex.between requires lower < upper"
        )

        // Appending is the overwhelmingly common case — every track added to the end
        // of a playlist — and bisecting towards the top of the alphabet is a bad way
        // to do it: each append lands halfway to the ceiling, so the room left
        // halves every time and keys grow a character every few appends. Measured,
        // a thousand appends reached 167 characters. Incrementing instead makes
        // appending behave like counting.
        if upper == nil { return increment(lower) }

        var result: [Character] = []
        var boundedAbove = upper
        var index = 0

        while true {
            let low = digit(lower, at: index) ?? 0
            let high = digit(boundedAbove, at: index) ?? base

            if high - low > 1 {
                // Room to land between them. The midpoint can never be digit zero
                // here — that would need low == 0 and high == 1, which fails this
                // test — so a generated key never *ends* in the smallest digit.
                // That invariant is what guarantees room remains to insert before
                // any existing key: nothing sorts between "" and "0", so a key of
                // "0" would be impossible to precede.
                result.append(alphabet[(low + high) / 2])
                return String(result)
            }

            // The digits are equal or adjacent, so this position can't separate
            // them. Keep the lower one and go deeper.
            result.append(alphabet[low])

            // Having taken a digit strictly below `upper`'s, every extension of this
            // prefix already sorts below `upper` — so it stops constraining us.
            // Without this the search would keep comparing against a branch it has
            // already left, and walk off the end of `upper` into keys that sort
            // *after* it.
            if low < high { boundedAbove = nil }

            index += 1
        }
    }

    /// Keys for `count` items appended after `lower`, in order.
    public static func sequence(after lower: String?, count: Int) -> [String] {
        var keys: [String] = []
        var previous = lower
        for _ in 0..<count {
            let key = between(previous, nil)
            keys.append(key)
            previous = key
        }
        return keys
    }

    /// The next key after `key`, and the shortest one available.
    private static func increment(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return String(alphabet[base / 2]) }

        var characters = Array(key)
        var index = characters.count - 1
        while index >= 0 {
            let value = alphabet.firstIndex(of: characters[index]) ?? 0
            if value + 1 < base {
                characters[index] = alphabet[value + 1]
                // Truncated: "V5" becomes "V6", but "Vz" becomes "W" rather than
                // "Wz" — the shorter key is still greater, and keeping the tail
                // would waste a character on every carry.
                return String(characters[0...index])
            }
            index -= 1
        }
        // Every digit is already the largest; the key has to get longer.
        return key + String(alphabet[base / 2])
    }

    private static func digit(_ key: String?, at index: Int) -> Int? {
        guard let key else { return nil }
        let characters = Array(key)
        guard index < characters.count else { return nil }
        return alphabet.firstIndex(of: characters[index])
    }
}
