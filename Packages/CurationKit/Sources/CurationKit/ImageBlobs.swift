// CryptoKit is Apple-only; Swift Crypto is Apple's own drop-in with the same
// API, so the call sites below are identical either way.
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GRDB

/// A cover this device holds, named by the SHA-256 of its own bytes.
///
/// The row is bookkeeping; the bytes live on disk beside the database. Content
/// addressing means the same picture chosen twice, or shared by two playlists, is one
/// blob — and that re-uploading is a no-op rather than a conflict to resolve.
public struct ImageBlob: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "imageBlob"

    public var hash: String
    public var mime: String
    public var bytes: Int
    public var createdAt: Millis
    /// `nil` until the server has these bytes. An op naming this hash must not be
    /// pushed before then.
    public var uploadedAt: Millis?

    public init(hash: String, mime: String, bytes: Int, createdAt: Millis, uploadedAt: Millis? = nil) {
        self.hash = hash
        self.mime = mime
        self.bytes = bytes
        self.createdAt = createdAt
        self.uploadedAt = uploadedAt
    }
}

public extension CurationStore {
    /// The SHA-256 the server will address these bytes by.
    ///
    /// Lower-case hex, and that matters: the server rejects a hash that does not match
    /// the bytes, and case is part of matching.
    nonisolated static func imageHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Records that this device holds these bytes. Local only — no op, because the
    /// blob is not itself synced state; the playlist row that names it is.
    @discardableResult
    func registerImage(
        hash: String,
        mime: String,
        bytes: Int,
        at now: Millis = Date().millis
    ) throws -> ImageBlob {
        let blob = ImageBlob(hash: hash, mime: mime, bytes: bytes, createdAt: now)
        try writeLocal { db in
            // Never overwrites: an existing row may already be marked uploaded, and
            // re-registering the same bytes must not make the server look as though it
            // has forgotten them.
            if try ImageBlob.fetchOne(db, key: hash) == nil { try blob.insert(db) }
        }
        return try image(hash) ?? blob
    }

    func image(_ hash: String) throws -> ImageBlob? {
        try read { db in try ImageBlob.fetchOne(db, key: hash) }
    }

    func markImageUploaded(_ hash: String, at now: Millis = Date().millis) throws {
        try writeLocal { db in
            try db.execute(
                sql: "UPDATE imageBlob SET uploadedAt = ? WHERE hash = ?",
                arguments: [now, hash]
            )
        }
    }

    /// Hashes named by ops still waiting to be pushed, whose bytes the server has not
    /// been given yet.
    ///
    /// This is the ordering rule made answerable: push must not run until this is
    /// empty, or another device pulls a playlist naming a cover it can never fetch.
    /// Read out of the payloads rather than tracked separately, so an op and its
    /// blob requirement cannot drift apart.
    func imagesNeededBeforePush() throws -> [ImageBlob] {
        try read { db in
            let hashes = try Row.fetchAll(db, sql: """
                SELECT DISTINCT b.hash AS hash
                FROM op o
                JOIN imageBlob b ON o.payload LIKE '%' || b.hash || '%'
                WHERE o.synced = 0 AND b.uploadedAt IS NULL
                """)
            let names = hashes.map { $0["hash"] as String }
            guard !names.isEmpty else { return [] }
            return try ImageBlob.filter(keys: names).fetchAll(db)
        }
    }

    /// How long a blob nothing references is kept before it is even considered for
    /// removal, matching the server's own sweep.
    ///
    /// The period exists because "nothing references this" is only ever true *here*.
    /// A cover dropped on this device may still be named by a playlist another device
    /// has not synced yet, and that device may be a phone in a drawer. Thirty days is
    /// long enough that a device out of contact for a month is a device that has been
    /// replaced.
    static let imageGraceDays = 30

    /// Blobs no live playlist names, older than the grace period, oldest first.
    ///
    /// Reports rather than reclaims. Deleting is the caller's decision because it is
    /// the one action here that cannot be undone by syncing again — and content
    /// addressing means keeping a stray blob costs a few kilobytes while dropping a
    /// live one costs an image nobody can get back.
    ///
    /// A shorter grace than the configured one is *raised* rather than honoured. A
    /// caller asking to sweep more aggressively is asking to defeat the reason the
    /// period exists, and the code that deletes data is the wrong place to take
    /// instructions about how careful to be.
    func orphanedImages(
        olderThanDays days: Int = CurationStore.imageGraceDays,
        now: Millis = Date().millis
    ) throws -> [ImageBlob] {
        let grace = max(days, Self.imageGraceDays)
        let cutoff = now - Millis(grace) * 24 * 60 * 60 * 1000

        return try read { db in
            // Every playlist that still names a hash, not one playlist at a time. A
            // blob shared by two playlists stays alive while either does — content
            // addressing makes sharing the normal case, and a per-playlist sweep
            // deletes a cover the other one is still using.
            try ImageBlob
                .filter(sql: """
                    createdAt < ? AND hash NOT IN (
                        SELECT imageHash FROM playlist WHERE imageHash IS NOT NULL AND deleted = 0
                    )
                    """, arguments: [cutoff])
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    /// Removes blobs this device is done with, and the files behind them.
    ///
    /// Takes the hashes rather than deciding for itself, so the decision and the
    /// deletion are separable — and so a caller cannot accidentally sweep by passing
    /// a shorter grace.
    @discardableResult
    func forgetImages(_ hashes: [String]) throws -> Int {
        guard !hashes.isEmpty else { return 0 }
        return try writeLocal { db in
            try ImageBlob.filter(keys: hashes).deleteAll(db)
        }
    }
}
