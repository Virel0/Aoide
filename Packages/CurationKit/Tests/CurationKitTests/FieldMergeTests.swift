import Foundation
import Testing
@testable import CurationKit

/// Row-level last-writer-wins throws away one of two edits whenever they touch the
/// same row, however unrelated. These pin that both survive.
@Suite("Per-field merging")
struct FieldMergeTests {
    private func store(_ device: String) throws -> CurationStore { try .inMemory(deviceId: device) }

    private func playlist(id: String, name: String, notes: String?, at: Millis, device: String) -> Playlist {
        Playlist(
            id: id, name: name, notes: notes, sortIndex: "V",
            updatedAt: at, originDevice: device
        )
    }

    /// The case the whole feature exists for: rename on the phone, describe on the
    /// laptop, neither knowing about the other.
    @Test("two devices editing different fields both win")
    func differentFieldsBothSurvive() throws {
        let phone = playlist(id: "p1", name: "Renamed", notes: "original", at: 200, device: "phone")
        var laptop = playlist(id: "p1", name: "Original", notes: "described", at: 100, device: "laptop")

        // Each device stamped only the field it actually touched.
        var phoneStamped = phone
        phoneStamped.fieldUpdatedAt = FieldStamps(["name": 200, "notes": 50])
        laptop.fieldUpdatedAt = FieldStamps(["name": 50, "notes": 100])

        let merged = try FieldMerge.merged(
            incoming: phoneStamped, existing: laptop, metadataFrom: phoneStamped
        )

        #expect(merged.name == "Renamed")
        #expect(merged.notes == "described")
    }

    /// Row-level LWW would have discarded this entirely.
    @Test("a row-level loser still contributes the field it changed last")
    func loserContributes() throws {
        var older = playlist(id: "p1", name: "Newer Name", notes: nil, at: 100, device: "a")
        older.fieldUpdatedAt = FieldStamps(["name": 100, "notes": 10])
        var newer = playlist(id: "p1", name: "Older Name", notes: "kept", at: 200, device: "b")
        newer.fieldUpdatedAt = FieldStamps(["name": 10, "notes": 200])

        let merged = try FieldMerge.merged(incoming: older, existing: newer, metadataFrom: newer)

        #expect(merged.name == "Newer Name")   // from the row-level loser
        #expect(merged.notes == "kept")
    }

    /// Ops written before stamps existed carry none, and must keep working against
    /// devices that do — otherwise this change would need a migration and a flag day.
    @Test("a row with no stamps falls back to its row timestamp")
    func backwardCompatible() throws {
        let old = playlist(id: "p1", name: "From Before", notes: "old notes", at: 300, device: "a")
        #expect(old.fieldUpdatedAt == nil)

        var recent = playlist(id: "p1", name: "Newer", notes: nil, at: 100, device: "b")
        recent.fieldUpdatedAt = FieldStamps(["name": 100])

        let merged = try FieldMerge.merged(incoming: old, existing: recent, metadataFrom: old)

        // The unstamped row's fields all date from 300, so they win on merit.
        #expect(merged.name == "From Before")
        #expect(merged.notes == "old notes")
    }

    @Test("a tie goes to the row-level winner, so every device agrees")
    func tiesAreDeterministic() throws {
        var a = playlist(id: "p1", name: "A", notes: nil, at: 100, device: "aaa")
        a.fieldUpdatedAt = FieldStamps(["name": 100])
        var b = playlist(id: "p1", name: "B", notes: nil, at: 100, device: "bbb")
        b.fieldUpdatedAt = FieldStamps(["name": 100])

        // Whichever side is handed in as the metadata winner supplies the tied field,
        // and both devices compute that winner identically.
        #expect(try FieldMerge.merged(incoming: a, existing: b, metadataFrom: b).name == "B")
        #expect(try FieldMerge.merged(incoming: b, existing: a, metadataFrom: b).name == "B")
    }

    @Test("writing a change stamps only the fields that actually changed")
    func stampsOnlyWhatChanged() throws {
        let store = try store("phone")
        let created = try store.createPlaylist(name: "First")
        let createdStamps = try #require(created.fieldUpdatedAt)

        var renamed = created
        renamed.name = "Second"
        let saved = try store.record(renamed, at: created.updatedAt + 1000)
        let stamps = try #require(saved.fieldUpdatedAt)

        #expect(stamps.time(of: "name", fallback: 0) == created.updatedAt + 1000)
        // sortIndex did not change, so its stamp must not move — a stamp that moves
        // on every write is the same as having no stamps at all.
        #expect(stamps.time(of: "sortIndex", fallback: 0)
                == createdStamps.time(of: "sortIndex", fallback: 0))
    }

    /// A delete is about the row, not any field. Stamping fields on delete would let
    /// it beat a concurrent rename it knew nothing about.
    @Test("a delete stamps no field")
    func deleteStampsNothing() throws {
        let store = try store("phone")
        let created = try store.createPlaylist(name: "Temporary")
        let before = try #require(created.fieldUpdatedAt).time(of: "name", fallback: 0)

        let deleted = try store.record(created, deleted: true, at: created.updatedAt + 5000)

        #expect(deleted.deleted)
        #expect(try #require(deleted.fieldUpdatedAt).time(of: "name", fallback: 0) == before)
    }

    /// Merging a queue field by field could pair one device's position with another's
    /// track list — a state that existed on neither.
    @Test("queue state is deliberately not field-merged")
    func queueStaysWhole() {
        #expect(!(QueueState.self is any FieldStamped.Type))
        #expect(!(PlaylistItem.self is any FieldStamped.Type))
        #expect(Playlist.self is any FieldStamped.Type)
        #expect(Folder.self is any FieldStamped.Type)
    }
}
