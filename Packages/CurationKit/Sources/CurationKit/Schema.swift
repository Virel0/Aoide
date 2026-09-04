import Foundation
import GRDB

/// The database's shape, versioned.
///
/// Migrations are registered once and never edited afterwards — an edited migration
/// runs only on devices that hadn't already applied it, so the schema silently
/// diverges between a phone that upgraded and one that installed fresh. Changes go
/// in a new migration, always.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // A schema change during development wipes and rebuilds rather than
        // demanding a migration for a shape nobody has shipped yet.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            // Local cache of what Jellyfin knows, so a playlist can render its rows
            // offline. Deliberately not synced: every device rebuilds it from its
            // own connection to the same server, and shipping it would dominate the
            // sync payload for no gain.
            try db.create(table: "track") { t in
                t.primaryKey("jellyfinId", .text)
                t.column("contentKey", .text).notNull().indexed()
                t.column("musicbrainzId", .text).indexed()
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("album", .text).notNull()
                t.column("albumArtist", .text)
                t.column("durationMs", .integer)
                t.column("year", .integer)
                t.column("genres", .text).notNull().defaults(to: "[]")
                t.column("lastSeenAt", .integer).notNull()
            }

            try db.create(table: "folder") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("parentId", .text).indexed()
                t.column("sortIndex", .text).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("originDevice", .text).notNull()
            }

            try db.create(table: "playlist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("notes", .text)
                t.column("folderId", .text).indexed()
                t.column("isSmart", .boolean).notNull().defaults(to: false)
                t.column("smartRules", .text)
                t.column("sortIndex", .text).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("originDevice", .text).notNull()
            }

            try db.create(table: "playlistItem") { t in
                t.primaryKey("id", .text)
                t.column("playlistId", .text).notNull()
                t.column("jellyfinId", .text).notNull()
                // Stored beside the id because Jellyfin ids are derived per-file: a
                // library rescan after files move mints new ones, and without this
                // every entry would dangle with no way back.
                t.column("contentKey", .text).notNull()
                t.column("position", .text).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("originDevice", .text).notNull()
            }
            try db.create(index: "idx_item_playlist", on: "playlistItem", columns: ["playlistId", "position"])

            try db.create(table: "like") { t in
                t.primaryKey("id", .text)
                t.column("jellyfinId", .text).notNull().unique()
                t.column("contentKey", .text).notNull()
                t.column("liked", .boolean).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("originDevice", .text).notNull()
            }

            // Append-only. Never updated after insert, which is what makes it the
            // easiest thing here to sync: there is no such thing as a conflicting
            // append. It is also the only honest source of play counts — Jellyfin
            // increments its own at playback *start*, so a four-second skip counts
            // there exactly as much as a full listen.
            try db.create(table: "playEvent") { t in
                t.primaryKey("id", .text)
                t.column("jellyfinId", .text).notNull().indexed()
                t.column("contentKey", .text).notNull()
                t.column("startedAt", .integer).notNull().indexed()
                t.column("endedAt", .integer)
                t.column("msPlayed", .integer).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("skipped", .boolean).notNull().defaults(to: false)
                t.column("source", .text)
                t.column("originDevice", .text).notNull()
            }

            // One row per device, so "resume on another device" reads the most
            // recent row belonging to somebody else.
            try db.create(table: "queueState") { t in
                t.primaryKey("deviceId", .text)
                t.column("deviceName", .text).notNull()
                t.column("trackIds", .text).notNull()
                t.column("position", .integer).notNull()
                t.column("elapsedMs", .integer).notNull()
                t.column("updatedAt", .integer).notNull()
                t.column("originDevice", .text).notNull()
            }

            // The outbound log. Written in the same transaction as the row it
            // describes — a row that changed without an op is a change that
            // silently never syncs.
            try db.create(table: "op") { t in
                t.primaryKey("opId", .text)
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("operation", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("synced", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_op_pending", on: "op", columns: ["synced", "createdAt"])

            try db.create(table: "syncState") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v2") { db in
            // Where ops go when they can never succeed — refused by the server,
            // invalid before they left, or inbound and unapplicable by this build.
            // They are *moved* out of `op` rather than flagged in it, because the
            // outbound queue is ordered and a dead row at its head blocks everything
            // behind it forever.
            //
            // The payload comes along. For an outbound op it is what makes the
            // failure diagnosable from the device it happened on; for an inbound one
            // it is the only copy, since the pull cursor has already moved past it
            // and the server will not offer it again. A future build that learns to
            // understand an entity this one had never heard of can replay it from
            // here.
            try db.create(table: "quarantinedOp") { t in
                t.primaryKey("opId", .text)
                t.column("entity", .text).notNull()
                t.column("entityId", .text).notNull()
                t.column("direction", .text).notNull()
                t.column("reason", .text).notNull()
                t.column("payload", .text).notNull()
                t.column("quarantinedAt", .integer).notNull()
            }
            try db.create(index: "idx_quarantine_time", on: "quarantinedOp", columns: ["quarantinedAt"])
        }

        // Never edit an earlier migration: it has already run on real devices, and a
        // changed one runs only where it had not, so the schema silently diverges
        // between a device that upgraded and one that installed fresh.
        migrator.registerMigration("v3") { db in
            // Nullable, and null is meaningful rather than merely absent: it marks a
            // row written before per-field merging existed, which falls back to the
            // row's own `updatedAt` for every field.
            for table in ["playlist", "folder"] {
                try db.alter(table: table) { t in
                    t.add(column: "fieldUpdatedAt", .text)
                }
            }
        }

        migrator.registerMigration("v4") { db in
            // Which Jellyfin playlist this was imported from, if any. Kept so a second
            // import refreshes the same local playlist instead of silently making a
            // duplicate — and so the server list can say which of its playlists are
            // already here.
            try db.alter(table: "playlist") { t in
                t.add(column: "sourceJellyfinId", .text)
            }
            try db.create(
                index: "idx_playlist_source", on: "playlist", columns: ["sourceJellyfinId"]
            )
        }

        migrator.registerMigration("v5") { db in
            // What a quarantined op needs to become a real op again. Without these a
            // change held back by a *server* fault could only ever be discarded, and
            // a server fault is the one kind here that gets fixed — the op is not
            // wrong, the server was. Nullable because rows quarantined before this
            // migration genuinely do not have them, and inventing a `createdAt` from
            // the quarantine time would put a lie in the op log's ordering.
            try db.alter(table: "quarantinedOp") { t in
                t.add(column: "operation", .text)
                t.add(column: "createdAt", .integer)
            }
        }

        migrator.registerMigration("v6") { db in
            // A Jellyfin item id whose Primary image is this playlist's cover — never
            // image bytes. The op log replays in full onto every fresh device and the
            // payload ceiling is 256 KB, so a cover stored as data would be the
            // largest thing in the system and would be copied forever. An id is
            // sixteen bytes and resolves against a server both devices already talk
            // to.
            try db.alter(table: "playlist") { t in
                t.add(column: "artworkItemId", .text)
            }
            // The album a cached track belongs to, so a playlist with no cover of its
            // own can be drawn from the albums it holds. The track cache is local and
            // rebuilt from Jellyfin, so a null here just means "not seen since this
            // column existed" and fills in on the next index.
            try db.alter(table: "track") { t in
                t.add(column: "albumId", .text)
            }
        }

        migrator.registerMigration("v7") { db in
            // A cover held as bytes somewhere else, named by the SHA-256 of those
            // bytes. Only the hash and the type travel in the op — a few dozen bytes
            // through the ordinary log, with no server change, because payloads are
            // opaque. The bytes go through their own endpoints.
            try db.alter(table: "playlist") { t in
                t.add(column: "imageHash", .text)
                t.add(column: "imageMime", .text)
            }

            // Which blobs this device holds, and whether the server has them yet.
            //
            // `uploadedAt` is the ordering rule made checkable: an op referencing a
            // hash must not be pushed until the bytes behind it are on the server, or
            // every other device sees a cover it cannot fetch. Keeping the answer
            // here rather than asking the server each time is what lets a sync that
            // has nothing new to upload cost nothing.
            try db.create(table: "imageBlob") { t in
                t.primaryKey("hash", .text)
                t.column("mime", .text).notNull()
                t.column("bytes", .integer).notNull()
                t.column("createdAt", .integer).notNull()
                t.column("uploadedAt", .integer)
            }
        }

        migrator.registerMigration("v8") { db in
            // Taste flags. See `TrackFlags` for why they are not columns on `like`.
            try db.create(table: "trackFlags") { t in
                t.primaryKey("id", .text)
                t.column("jellyfinId", .text).notNull().unique()
                t.column("contentKey", .text).notNull()
                t.column("notInterested", .boolean).notNull().defaults(to: false)
                t.column("dontCount", .boolean).notNull().defaults(to: false)
                t.column("updatedAt", .integer).notNull()
                t.column("deleted", .boolean).notNull().defaults(to: false)
                t.column("originDevice", .text).notNull()
                t.column("fieldUpdatedAt", .text)
            }
        }

        return migrator
    }
}
