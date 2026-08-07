import Foundation
import GRDB

/// When each field of a row was last changed.
///
/// Row-level last-writer-wins throws away one of two edits whenever they touch the
/// same row, however unrelated they were: rename a playlist on the phone while
/// adding a description on the laptop, and whichever synced second erases the other.
/// Stamping fields individually lets both survive.
///
/// Carried *inside* the payload rather than beside it, which is why this needed no
/// server change: the sidecar stores payloads verbatim and never parses them, so a
/// new field is a client-only concern. Ops written before this existed carry no
/// stamps at all and fall back to the row's `updatedAt`, so older ops in the log and
/// devices on older builds keep working and keep interoperating.
public struct FieldStamps: Codable, Hashable, Sendable, ExpressibleByDictionaryLiteral {
    public private(set) var stamps: [String: Millis]

    public init(_ stamps: [String: Millis] = [:]) { self.stamps = stamps }

    public init(dictionaryLiteral elements: (String, Millis)...) {
        stamps = Dictionary(elements, uniquingKeysWith: { first, _ in first })
    }

    public init(from decoder: any Decoder) throws {
        stamps = try [String: Millis](from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try stamps.encode(to: encoder)
    }

    /// When `field` last changed, or `fallback` for a row written before stamps
    /// existed — which is the whole of the backward compatibility story.
    public func time(of field: String, fallback: Millis) -> Millis {
        stamps[field] ?? fallback
    }

    public mutating func stamp(_ fields: some Sequence<String>, at now: Millis) {
        for field in fields { stamps[field] = now }
    }

    /// Drags any stamp that fails `isCredible` back to a time the server witnessed.
    ///
    /// These come from the same clock as the row's `updatedAt` and need the same
    /// correction. Correcting only the row timestamp left a device stamping the year
    /// 2096 losing the row comparison — and then winning every individual field
    /// anyway, which is the capture the correction exists to prevent, reintroduced
    /// one field at a time.
    mutating func correctingSkew(credible: (Millis) -> Bool, to receivedAt: Millis) -> Bool {
        var corrected = false
        for (field, time) in stamps where !credible(time) {
            stamps[field] = receivedAt
            corrected = true
        }
        return corrected
    }
}

/// A row whose fields are merged individually rather than whole.
///
/// Only `playlist` and `folder` need this. `playlistItem` and `like` have exactly one
/// mutable field each, so per-row already *is* per-field; `playEvent` is append-only
/// and cannot conflict; and `queueState` is deliberately excluded — merging a queue
/// field by field could pair one device's playback position with another device's
/// track list, a combination that existed on neither and describes nothing.
public protocol FieldStamped: Syncable {
    var fieldUpdatedAt: FieldStamps? { get set }

    /// Columns that carry no content and are never merged independently: they come
    /// from whichever side wins the row as a whole.
    static var metadataColumns: Set<String> { get }
}

public extension FieldStamped {
    static var metadataColumns: Set<String> {
        ["id", "updatedAt", "deleted", "originDevice", "fieldUpdatedAt"]
    }
}

enum FieldMerge {
    /// Which content fields differ between two versions of a row.
    static func changedFields<R: Encodable & FieldStamped>(_ new: R, from old: R?) throws -> Set<String> {
        let newFields = try dictionary(new)
        guard let old else { return Set(newFields.keys) }
        let oldFields = try dictionary(old)
        return Set(newFields.filter { key, value in oldFields[key] != value }.keys)
    }

    /// Builds one row from two, taking each content field from whichever side changed
    /// it more recently and the metadata from `metadataFrom`.
    ///
    /// Works through the encoded form rather than a hand-written field list. A merge
    /// written field by field silently stops covering a column the moment somebody
    /// adds one, and the resulting bug — that one specific field never merges — is
    /// invisible until two people happen to edit it at once.
    static func merged<R: Codable & FieldStamped>(
        incoming: R,
        existing: R,
        metadataFrom winner: R
    ) throws -> R {
        let incomingFields = try dictionary(incoming)
        let existingFields = try dictionary(existing)
        var result = try dictionary(winner)

        var stamps = winner.fieldUpdatedAt ?? FieldStamps()
        let incomingStamps = incoming.fieldUpdatedAt ?? FieldStamps()
        let existingStamps = existing.fieldUpdatedAt ?? FieldStamps()

        for key in Set(incomingFields.keys).union(existingFields.keys)
        where !R.metadataColumns.contains(key) {
            let incomingStamp = incomingStamps.stamps[key]
            let existingStamp = existingStamps.stamps[key]
            let incomingTime = incomingStamp ?? incoming.updatedAt
            let existingTime = existingStamp ?? existing.updatedAt

            // Ties are left alone deliberately: `result` already holds the row-level
            // winner's value, and every device computes that winner identically, so a
            // tie resolves the same way everywhere instead of by whoever synced first.
            if incomingTime > existingTime {
                result[key] = incomingFields[key]
            } else if existingTime > incomingTime {
                result[key] = existingFields[key]
            }

            // Only where a stamp genuinely exists. Synthesising one for a field
            // neither side stamped would turn a pair of rows written before this
            // feature into a row that differs from both — so re-applying an op would
            // write every time and never settle, which is the whole idempotency
            // guarantee gone.
            if incomingStamp != nil || existingStamp != nil {
                stamps.stamp([key], at: max(incomingTime, existingTime))
            }
        }

        var merged = try value(R.self, from: result)
        // Left nil when nothing was ever stamped, rather than becoming an empty set.
        // An empty `FieldStamps` is not equal to `nil`, so merging two rows that both
        // predate this feature would produce a row differing from both — and applying
        // the same op twice would write every time instead of settling.
        merged.fieldUpdatedAt = stamps.stamps.isEmpty ? nil : stamps
        return merged
    }

    private static func dictionary(_ row: some Encodable) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(row)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func value<R: Decodable>(_ type: R.Type, from fields: [String: JSONValue]) throws -> R {
        try JSONDecoder().decode(R.self, from: JSONEncoder().encode(fields))
    }
}
