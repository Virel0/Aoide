import Foundation

/// Jellyfin has shipped both PascalCase (`"Name"`) and camelCase (`"name"`) JSON
/// depending on server version and endpoint. Rather than pin ourselves to one and
/// break on the other, we normalise every incoming key by lowercasing its first
/// character — which turns `"AlbumArtist"` into `"albumArtist"` and leaves an
/// already-camelCase `"albumArtist"` untouched.
struct FirstCharLowercasedKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    static func normalising(_ path: [any CodingKey]) -> any CodingKey {
        guard let last = path.last else { return FirstCharLowercasedKey(stringValue: "") }
        if let intValue = last.intValue { return FirstCharLowercasedKey(intValue: intValue) }
        let key = last.stringValue
        guard let first = key.first, first.isUppercase else { return last }
        return FirstCharLowercasedKey(stringValue: first.lowercased() + key.dropFirst())
    }
}

extension JSONDecoder {
    /// The decoder every Jellyfin response goes through.
    static var jellyfin: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { FirstCharLowercasedKey.normalising($0) }
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = JellyfinDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Not an ISO 8601 date: \(raw)"
                )
            }
            return date
        }
        return decoder
    }
}

/// Jellyfin emits ISO 8601 both with and without fractional seconds, sometimes with
/// seven digits of them, depending on the field and the server version. A single
/// `ISO8601DateFormatter` handles exactly one of those shapes, so we try both.
enum JellyfinDate {
    // `nonisolated(unsafe)` because Foundation's date formatters are documented as
    // thread-safe for parsing, but aren't marked `Sendable`. Configured once here
    // and never mutated again, which is the condition that makes that safe.
    private nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        // .NET can emit more than the three fractional digits ISO8601DateFormatter
        // accepts; trimming the excess is cheaper than a DateFormatter round trip.
        var normalised = raw
        if let dot = raw.firstIndex(of: "."),
           let tzStart = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = raw[raw.index(after: dot)..<tzStart]
            if digits.count > 3 {
                normalised = String(raw[..<dot]) + "." + digits.prefix(3) + String(raw[tzStart...])
            }
        }
        return withFraction.date(from: normalised) ?? plain.date(from: normalised)
    }
}

extension JSONEncoder {
    /// Jellyfin request bodies are PascalCase across every server version we support,
    /// so we encode with explicit `CodingKeys` on each request type rather than a strategy.
    static var jellyfin: JSONEncoder {
        JSONEncoder()
    }
}
