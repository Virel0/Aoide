import Foundation

extension JSONDecoder {
    /// Melete's API is snake_case throughout (`album_id`, `duration_seconds`), and
    /// its times are Unix seconds, not dates.
    ///
    /// Not for the `/aoide/*` routes: their op payloads are opaque client JSON in
    /// camelCase that the server stores verbatim, and converting keys would sync a
    /// row into a different shape than it left. Those hand back raw bytes.
    static var melete: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    static var melete: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
