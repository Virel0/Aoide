import CurationKit
import Foundation
import os

/// The last things this device was in, kept on disk. See ``RecentContext``.
@MainActor
@Observable
final class RecentContextStore {
    static let shared = RecentContextStore()

    private(set) var list = RecentContextList()
    private let log = Logger(subsystem: AppIdentity.bundle, category: "home")

    @ObservationIgnored private let url: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recent-contexts.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(RecentContextList.self, from: data) {
            list = saved
        }
    }

    func remember(_ context: RecentContext) {
        list.remember(context)
        save()
    }

    func forget(_ context: RecentContext) {
        list.forget(key: context.key)
        save()
    }

    func removeAll() {
        list = RecentContextList()
        try? FileManager.default.removeItem(at: url)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
