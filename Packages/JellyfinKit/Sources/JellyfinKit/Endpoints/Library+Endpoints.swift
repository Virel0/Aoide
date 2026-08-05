import Foundation

/// Sort orders Jellyfin understands, named for how the UI describes them.
public enum ItemSort: String, Sendable {
    case name = "SortName"
    case dateAdded = "DateCreated"
    case datePlayed = "DatePlayed"
    case playCount = "PlayCount"
    case releaseDate = "PremiereDate,ProductionYear,SortName"
    case random = "Random"
    /// Disc, then track, then title — the only correct order for an album's contents.
    case albumTrackOrder = "ParentIndexNumber,IndexNumber,SortName"
}

public enum SortDirection: String, Sendable {
    case ascending = "Ascending"
    case descending = "Descending"
}

extension JellyfinClient {
    /// Fields absent from Jellyfin's default response that the UI needs. Requesting
    /// them per-call rather than globally keeps large library pages small.
    private static let standardFields = "Genres,AlbumArtist,Artists,ParentId,ChildCount,PrimaryImageAspectRatio"

    // MARK: - Libraries

    /// The user's music libraries. A server may host several, or none at all if the
    /// user only has movie libraries shared with them.
    public func musicLibraries() async throws -> [JellyfinItem] {
        let userId = try requireUserId()
        let response: ItemsResponse = try await get(
            path: "UserViews",
            query: [URLQueryItem(name: "userId", value: userId)]
        )
        return response.items.filter { $0.collectionType == "music" }
    }

    // MARK: - Browsing

    public func albums(
        parentId: String? = nil,
        sort: ItemSort = .name,
        direction: SortDirection = .ascending,
        startIndex: Int = 0,
        limit: Int? = nil
    ) async throws -> ItemsResponse {
        try await items(
            includeTypes: ["MusicAlbum"],
            parentId: parentId,
            sort: sort,
            direction: direction,
            startIndex: startIndex,
            limit: limit
        )
    }

    public func albumArtists(parentId: String? = nil, startIndex: Int = 0, limit: Int? = nil) async throws -> ItemsResponse {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "sortBy", value: ItemSort.name.rawValue),
            URLQueryItem(name: "sortOrder", value: SortDirection.ascending.rawValue),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(path: "Artists/AlbumArtists", query: query)
    }

    /// An album's tracks, already in disc/track order.
    public func tracks(inAlbum albumId: String) async throws -> [JellyfinItem] {
        let response = try await items(
            includeTypes: ["Audio"],
            parentId: albumId,
            sort: .albumTrackOrder,
            direction: .ascending
        )
        return response.items
    }

    /// Every album credited to an artist.
    public func albums(byArtist artistId: String) async throws -> [JellyfinItem] {
        let userId = try requireUserId()
        let query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "albumArtistIds", value: artistId),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: ItemSort.releaseDate.rawValue),
            URLQueryItem(name: "sortOrder", value: SortDirection.descending.rawValue),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        let response: ItemsResponse = try await get(path: "Items", query: query)
        return response.items
    }

    public func playlists() async throws -> [JellyfinItem] {
        let response = try await items(includeTypes: ["Playlist"], sort: .name, direction: .ascending)
        return response.items
    }

    public func tracks(inPlaylist playlistId: String) async throws -> [JellyfinItem] {
        let userId = try requireUserId()
        let query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        let response: ItemsResponse = try await get(path: "Playlists/\(playlistId)/Items", query: query)
        return response.items
    }

    public func item(id: String) async throws -> JellyfinItem {
        let userId = try requireUserId()
        return try await get(
            path: "Users/\(userId)/Items/\(id)",
            query: [URLQueryItem(name: "fields", value: Self.standardFields)]
        )
    }

    // MARK: - Home screen shelves

    public func recentlyAdded(limit: Int = 20) async throws -> [JellyfinItem] {
        try await items(
            includeTypes: ["MusicAlbum"],
            sort: .dateAdded,
            direction: .descending,
            limit: limit
        ).items
    }

    public func mostPlayed(limit: Int = 20) async throws -> [JellyfinItem] {
        try await items(
            includeTypes: ["MusicAlbum"],
            sort: .playCount,
            direction: .descending,
            filters: ["IsPlayed"],
            limit: limit
        ).items
    }

    public func favoriteTracks(limit: Int? = nil) async throws -> [JellyfinItem] {
        try await items(
            includeTypes: ["Audio"],
            sort: .name,
            direction: .ascending,
            filters: ["IsFavorite"],
            limit: limit
        ).items
    }

    // MARK: - Search

    public func search(_ term: String, limit: Int = 40) async throws -> [JellyfinItem] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await items(
            includeTypes: ["Audio", "MusicAlbum", "MusicArtist", "Playlist"],
            searchTerm: trimmed,
            sort: .name,
            direction: .ascending,
            limit: limit
        ).items
    }

    // MARK: - Radio

    /// Jellyfin's "Instant Mix" — a station seeded from any track, album, or artist.
    public func instantMix(seededBy itemId: String, limit: Int = 200) async throws -> [JellyfinItem] {
        let userId = try requireUserId()
        let query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        let response: ItemsResponse = try await get(path: "Items/\(itemId)/InstantMix", query: query)
        return response.items
    }

    // MARK: - Favourites

    @discardableResult
    public func setFavorite(_ isFavorite: Bool, itemId: String) async throws -> UserItemData {
        let userId = try requireUserId()
        let path = "Users/\(userId)/FavoriteItems/\(itemId)"
        return isFavorite
            ? try await post(UserItemData.self, path: path, body: Optional<Never>.none)
            : try await delete(UserItemData.self, path: path)
    }

    // MARK: - Shared query builder

    /// Every list endpoint above funnels through here, so paging, sorting, and the
    /// requested field set stay consistent across the app.
    private func items(
        includeTypes: [String],
        parentId: String? = nil,
        searchTerm: String? = nil,
        sort: ItemSort,
        direction: SortDirection,
        filters: [String] = [],
        startIndex: Int = 0,
        limit: Int? = nil
    ) async throws -> ItemsResponse {
        let userId = try requireUserId()
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "includeItemTypes", value: includeTypes.joined(separator: ",")),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sort.rawValue),
            URLQueryItem(name: "sortOrder", value: direction.rawValue),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "fields", value: Self.standardFields),
        ]
        if let parentId { query.append(URLQueryItem(name: "parentId", value: parentId)) }
        if let searchTerm { query.append(URLQueryItem(name: "searchTerm", value: searchTerm)) }
        if !filters.isEmpty { query.append(URLQueryItem(name: "filters", value: filters.joined(separator: ","))) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await get(path: "Items", query: query)
    }
}
