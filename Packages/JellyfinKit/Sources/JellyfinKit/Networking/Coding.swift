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
        return decoder
    }
}

extension JSONEncoder {
    /// Jellyfin request bodies are PascalCase across every server version we support,
    /// so we encode with explicit `CodingKeys` on each request type rather than a strategy.
    static var jellyfin: JSONEncoder {
        JSONEncoder()
    }
}
