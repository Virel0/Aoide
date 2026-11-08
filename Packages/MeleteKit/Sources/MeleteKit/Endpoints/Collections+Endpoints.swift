import Foundation

extension MeleteClient {
    // MARK: - Collections

    /// The listener's collections, by name. None from a server before 0.8,
    /// which hasn't the route.
    public func collections() async throws -> [SongCollection] {
        struct Page: Decodable { let items: [SongCollection] }
        do {
            let page: Page = try await get(path: "api/v1/music/collections")
            return page.items
        } catch MeleteError.notFound {
            return []
        }
    }

    /// Deletes one of the listener's collections; its songs stay in the library.
    public func deleteCollection(_ id: Int64) async throws {
        try await sendIgnoringResponse("DELETE", path: "api/v1/music/collections/\(id)")
    }

    /// A page of `collection`'s songs, by artist, album and track. `shuffled`
    /// takes them in the server's random order over the whole collection; its
    /// later pages would need the order's seed, so ask a shuffle for one page.
    public func songs(
        in collection: SongCollection, shuffled: Bool = false, startIndex: Int = 0, limit: Int
    ) async throws -> ItemsResponse {
        try await list(
            WireTrack.self, "tracks",
            filters: collection.filters,
            sort: shuffled ? "random" : nil,
            startIndex: startIndex,
            limit: limit
        ) { $0.item }
    }
}
