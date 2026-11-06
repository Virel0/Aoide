import Foundation

extension CurationStore {
    /// Creates the built-in smart playlists this library has never had, and puts the
    /// rules back on one that has lost them. Returns the ones it wrote.
    ///
    /// Call it only once this store has synced with the server. Before that, a
    /// built-in the server already has isn't here yet, and creating it again would
    /// write a newer copy that wins on every device.
    ///
    /// Each is one write, the row with its rules. Written as two ops at the same
    /// instant (as Aoide for Linux once did), the rules lose the merge's tie on
    /// every other device and leave a plain, empty playlist under the built-in's
    /// name; such a row is repaired here with its rules. One deleted stays deleted.
    @discardableResult
    public func ensureBuiltInPlaylists(now: Millis = Date().millis) throws -> [BuiltInPlaylist] {
        var written: [BuiltInPlaylist] = []
        for built in BuiltInPlaylist.allCases {
            let rules = try built.rules
            if let row = try read({ db in try Playlist.fetchOne(db, key: built.id) }) {
                guard !row.deleted, (try? row.smartRuleSet()) ?? nil == nil else { continue }
                try record(row.settingSmartRules(rules), at: now)
            } else {
                try createPlaylist(name: built.name, notes: built.notes, id: built.id, smartRules: rules, now: now)
            }
            written.append(built)
        }
        return written
    }
}
