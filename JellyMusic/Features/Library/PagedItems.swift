import Foundation
import JellyfinKit
import os

/// A lazily-paged list of library items.
///
/// A personal library can hold tens of thousands of tracks, and loading them in one
/// request means a long blank screen, a large decode, and a list SwiftUI has to
/// build in full before it draws anything. This fetches a page at a time as the
/// user approaches the end.
@MainActor
@Observable
final class PagedItems {
    private(set) var items: [JellyfinItem] = []
    private(set) var isLoadingFirstPage = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?

    /// Total the server reports, so we know when to stop asking.
    private(set) var total: Int?

    /// 200 is a compromise: large enough that scrolling rarely outruns it on a home
    /// connection, small enough that the first page appears quickly.
    private let pageSize = 200

    /// Start the next page this many rows before the end, so it's usually already
    /// there by the time the user reaches the bottom.
    private let prefetchMargin = 40

    private let fetch: @MainActor (_ startIndex: Int, _ limit: Int) async throws -> ItemsResponse
    private let log = Logger(subsystem: "com.example.jellymusic", category: "paging")

    init(fetch: @escaping @MainActor (_ startIndex: Int, _ limit: Int) async throws -> ItemsResponse) {
        self.fetch = fetch
    }

    var hasMore: Bool {
        guard let total else { return true }
        return items.count < total
    }

    var isEmpty: Bool { items.isEmpty && !isLoadingFirstPage && errorMessage == nil }

    func loadFirstPageIfNeeded() async {
        guard items.isEmpty, !isLoadingFirstPage, errorMessage == nil else { return }
        isLoadingFirstPage = true
        await loadPage(startIndex: 0)
        isLoadingFirstPage = false
    }

    /// Called as rows appear. Cheap to call for every row — it exits immediately
    /// unless the row is near the end and nothing is already in flight.
    func loadMoreIfNeeded(currentItem item: JellyfinItem) async {
        guard !isLoadingMore, !isLoadingFirstPage, hasMore else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        guard index >= items.count - prefetchMargin else { return }

        isLoadingMore = true
        await loadPage(startIndex: items.count)
        isLoadingMore = false
    }

    func reload() async {
        items = []
        total = nil
        errorMessage = nil
        await loadFirstPageIfNeeded()
    }

    private func loadPage(startIndex: Int) async {
        do {
            let response = try await fetch(startIndex, pageSize)
            // Guard against a concurrent reload having emptied us mid-flight.
            guard startIndex == 0 || startIndex == items.count else { return }
            if startIndex == 0 { items = response.items } else { items += response.items }
            total = response.totalRecordCount

            // A server that reports a total it then won't serve would loop forever.
            if response.items.isEmpty { total = items.count }
        } catch is CancellationError {
            // Navigating away cancels the page. Recording that as an error left a
            // permanent "cancelled" message on the screen when you came back,
            // because `loadFirstPageIfNeeded` refuses to retry once errorMessage is
            // set.
            return
        } catch {
            if Task.isCancelled { return }
            if case JellyfinError.unauthorized = error {
                AppSession.shared.invalidateSession()
                return
            }
            let message = (error as? JellyfinError)?.errorDescription ?? error.localizedDescription
            log.error("Page load failed at \(startIndex, privacy: .public): \(message, privacy: .public)")
            // Only surface the error if there's nothing on screen; failing to extend
            // a list the user is already reading shouldn't replace it with an error.
            if items.isEmpty { errorMessage = message }
        }
    }
}
