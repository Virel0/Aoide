import Foundation

extension MeleteClient {
    /// The largest page Melete serves; a list asked for whole is read in pages
    /// this big.
    static let maxPage = 500
    /// Melete takes at most this many ids in one `?id=`.
    static let maxIdsPerRequest = 100

    // MARK: - Browsing

    public func albums(
        sort: ItemSort = .name,
        direction: SortDirection = .ascending,
        startIndex: Int = 0,
        limit: Int? = nil
    ) async throws -> ItemsResponse {
        try await list(WireAlbum.self, "albums", sort: sort.forAlbums, startIndex: startIndex, limit: limit) { $0.item }
    }

    /// Artists with an album in the library, or a track crediting them.
    public func albumArtists(
        searchTerm: String? = nil,
        startIndex: Int = 0,
        limit: Int? = nil
    ) async throws -> ItemsResponse {
        var filters: [URLQueryItem] = []
        if let searchTerm, !searchTerm.isEmpty { filters.append(URLQueryItem(name: "q", value: searchTerm)) }
        return try await list(
            WireArtist.self, "artists", filters: filters, startIndex: startIndex, limit: limit
        ) { $0.item }
    }

    public func songs(
        sort: ItemSort = .name,
        direction: SortDirection = .ascending,
        startIndex: Int = 0,
        limit: Int? = nil
    ) async throws -> ItemsResponse {
        try await list(WireTrack.self, "tracks", sort: sort.forTracks, startIndex: startIndex, limit: limit) { $0.item }
    }

    /// An album and its tracks, in disc and track order.
    public func album(id: String) async throws -> (album: MusicItem, tracks: [MusicItem]) {
        struct Detail: Decodable {
            let album: WireAlbum
            let trackList: [WireTrack]
            init(from decoder: any Decoder) throws {
                album = try WireAlbum(from: decoder)
                let c = try decoder.container(keyedBy: CodingKeys.self)
                trackList = try c.decode([WireTrack].self, forKey: .trackList)
            }
            enum CodingKeys: String, CodingKey { case trackList }
        }
        let detail: Detail = try await get(path: "api/v1/music/albums/\(id)")
        return (detail.album.item, detail.trackList.map(\.item))
    }

    public func tracks(inAlbum albumId: String) async throws -> [MusicItem] {
        try await album(id: albumId).tracks
    }

    /// An artist's own albums, then the ones they appear on.
    public func albums(byArtist artistId: String) async throws -> [MusicItem] {
        struct Detail: Decodable {
            let albumList: [WireAlbum]
            let appearsOnList: [WireAlbum]
        }
        let detail: Detail = try await get(path: "api/v1/music/artists/\(artistId)")
        return (detail.albumList + detail.appearsOnList).map(\.item)
    }

    /// One artist.
    public func artist(id: String) async throws -> MusicItem {
        let artist: WireArtist = try await get(path: "api/v1/music/artists/\(id)")
        return artist.item
    }

    /// An artist's songs: their own albums' and the ones crediting them elsewhere.
    public func songs(byArtist artistId: String, limit: Int? = nil) async throws -> [MusicItem] {
        try await list(
            WireTrack.self, "tracks",
            filters: [URLQueryItem(name: "artist_id", value: artistId)],
            limit: limit
        ) { $0.item }.items
    }

    /// One track.
    public func item(id: String) async throws -> MusicItem {
        guard let item = try await items(ids: [id]).first else {
            throw MeleteError.notFound(path: "api/v1/music/tracks/\(id)")
        }
        return item
    }

    /// Tracks by id, in the order asked for; one the server no longer has is
    /// simply absent, which is how a caller tells an entry has dangled.
    public func items(ids: [String]) async throws -> [MusicItem] {
        guard !ids.isEmpty else { return [] }
        var found: [String: MusicItem] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.maxIdsPerRequest) {
            let slice = Array(ids[chunk..<min(chunk + Self.maxIdsPerRequest, ids.count)])
            let page: WirePage<WireTrack> = try await get(
                path: "api/v1/music/tracks",
                query: [
                    URLQueryItem(name: "id", value: slice.joined(separator: ",")),
                    URLQueryItem(name: "limit", value: String(Self.maxIdsPerRequest)),
                ]
            )
            for track in page.items { found[String(track.id)] = track.item }
        }
        return ids.compactMap { found[$0] }
    }

    // MARK: - Genres

    /// Every genre, most tracks first; each one's id is its name.
    public func musicGenres(limit: Int? = nil) async throws -> [MusicItem] {
        let genres: [WireGenre] = try await get(path: "api/v1/music/genres")
        let items = genres.map(\.item)
        return limit.map { Array(items.prefix($0)) } ?? items
    }

    public func albums(inGenre genre: String, limit: Int? = nil) async throws -> [MusicItem] {
        try await list(
            WireAlbum.self, "albums",
            filters: [URLQueryItem(name: "genre", value: genre)],
            limit: limit
        ) { $0.item }.items
    }

    public func songs(inGenre genre: String, limit: Int? = nil) async throws -> [MusicItem] {
        try await list(
            WireTrack.self, "tracks",
            filters: [URLQueryItem(name: "genre", value: genre)],
            limit: limit
        ) { $0.item }.items
    }

    // MARK: - Search

    /// Artists, albums and tracks matching `term`, in that order.
    public func search(_ term: String, limit: Int = 40) async throws -> [MusicItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let words = [URLQueryItem(name: "q", value: trimmed)]
        async let artists = albumArtists(searchTerm: trimmed, limit: limit).items
        async let albums = list(WireAlbum.self, "albums", filters: words, limit: limit) { $0.item }.items
        async let songs = list(WireTrack.self, "tracks", filters: Self.songWords(trimmed), limit: limit) { $0.item }.items
        return try await artists + albums + songs
    }

    public func songs(searching term: String, limit: Int = 15) async throws -> [MusicItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await list(
            WireTrack.self, "tracks",
            filters: Self.songWords(trimmed),
            limit: limit
        ) { $0.item }.items
    }

    /// A song search: the song's own title and artist (`q_in=track`), so an
    /// album's name doesn't bring every track on it. Servers before Melete 0.2.0
    /// ignore `q_in`.
    static func songWords(_ term: String) -> [URLQueryItem] {
        [URLQueryItem(name: "q", value: term), URLQueryItem(name: "q_in", value: "track")]
    }

    /// About `count` songs from all over the library: small pages read at random
    /// places, since Melete has no random order. Fewer when the library is small.
    public func randomSongs(count: Int) async throws -> [MusicItem] {
        let pageSize = 25
        let total = try await songs(limit: 1).totalRecordCount
        var seen = Set<String>()
        var found: [MusicItem] = []
        let room = max(total - pageSize, 0)
        for _ in 0..<max((count + pageSize - 1) / pageSize, 1) {
            let start = room == 0 ? 0 : Int.random(in: 0...room)
            found += try await songs(startIndex: start, limit: pageSize).items.filter { seen.insert($0.id).inserted }
            if room == 0 { break }
        }
        return found.shuffled()
    }

    // MARK: - Shared list reading

    /// A list's page, or the whole list read 500 at a time when there's no limit.
    func list<Wire: Decodable>(
        _ wire: Wire.Type,
        _ name: String,
        filters: [URLQueryItem] = [],
        sort: String? = nil,
        startIndex: Int = 0,
        limit: Int? = nil,
        item: (Wire) -> MusicItem
    ) async throws -> ItemsResponse {
        let path = "api/v1/music/\(name)"
        var base = filters
        if let sort { base.append(URLQueryItem(name: "sort", value: sort)) }
        func page(_ offset: Int, _ size: Int) async throws -> WirePage<Wire> {
            try await get(path: path, query: base + [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(size)),
            ])
        }
        if let limit {
            let one = try await page(startIndex, min(max(limit, 1), Self.maxPage))
            return ItemsResponse(items: one.items.map(item), totalRecordCount: one.total, startIndex: startIndex)
        }
        var items: [MusicItem] = []
        var total = 0
        while true {
            let one = try await page(startIndex + items.count, Self.maxPage)
            total = one.total
            items += one.items.map(item)
            if one.items.isEmpty || startIndex + items.count >= total { break }
        }
        return ItemsResponse(items: items, totalRecordCount: total, startIndex: startIndex)
    }
}
