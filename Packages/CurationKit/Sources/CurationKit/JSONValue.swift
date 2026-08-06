import Foundation

/// A parsed JSON document, used for op payloads in transit.
///
/// Payloads are stored locally as text and travel as JSON *objects*, so something
/// has to sit between the two. Parsing into this rather than re-emitting the stored
/// string verbatim buys the three checks only the client can make: that the payload
/// really is an object, that its identity field matches the op's `entityId`, and
/// that a delete carries its flag. The server stores payloads without looking
/// inside, so if this does not check them nothing does.
///
/// Integers are a separate case from doubles because `updatedAt` is milliseconds
/// since the epoch and every conflict in the system is decided by comparing two of
/// them. Round-tripping those through `Double` would be lossless today and silently
/// stop being lossless later.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case .string(let value) = self { value } else { nil }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let fields) = self { fields } else { nil }
    }

    /// Whether a flag column reads as set.
    ///
    /// Accepts both spellings because the two ends disagree in writing: this app
    /// encodes `deleted` from a Swift `Bool`, so it goes out as JSON `true`, while
    /// the sync contract writes the invariant as `deleted = 1` after the SQLite
    /// column. Nothing inspects payloads between here and another client, so both
    /// have to be readable.
    public var isFlagSet: Bool {
        switch self {
        case .bool(let flag): flag
        case .int(let number): number != 0
        default: false
        }
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Before the numeric cases: a decoder that tolerates `true` as 1 would
            // otherwise turn every boolean column into an integer on the way through.
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not JSON this decoder recognises"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let value):
            try value.encode(to: encoder)
        case .object(let value):
            try value.encode(to: encoder)
        }
    }
}
