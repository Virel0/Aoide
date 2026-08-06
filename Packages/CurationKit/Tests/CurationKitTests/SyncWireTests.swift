import Foundation
import Testing
@testable import CurationKit

@Suite("Sync wire format")
struct SyncWireTests {
    private func op(
        entity: String = "playlist",
        entityId: String = "list-1",
        operation: Op.Kind = .upsert,
        payload: String? = nil,
        opId: String = UUID().uuidString,
        createdAt: Millis = 1_700_000_000_000
    ) throws -> Op {
        let body = try payload ?? Wire.text(Wire.payload(
            makePlaylist(id: entityId, updatedAt: createdAt, device: "phone")
        ))
        return Op(
            opId: opId,
            entity: entity,
            entityId: entityId,
            operation: operation,
            payload: body,
            createdAt: createdAt
        )
    }

    private func fault(_ result: Result<WireOp, SyncFault>) -> SyncFault? {
        if case .failure(let fault) = result { fault } else { nil }
    }

    // MARK: - Translation

    @Test("a valid op converts, with its entity translated")
    func validOp() throws {
        let result = WireOp.make(from: try op())
        let wire = try #require(try? result.get())
        #expect(wire.entity == "playlists")
        #expect(wire.operation == "upsert")
        #expect(wire.entityId == "list-1")
        #expect(wire.payload.objectValue?["name"]?.stringValue == "Late Night")
    }

    @Test("queue state converts, identified by its device")
    func queueStateOp() throws {
        let state = QueueState(
            deviceId: "phone",
            deviceName: "iPhone",
            trackIds: ["a", "b"],
            position: 0,
            elapsedMs: 0,
            updatedAt: 1_000
        )
        let result = WireOp.make(from: Op(
            entity: QueueState.databaseTableName,
            entityId: "phone",
            operation: .upsert,
            payload: try Wire.text(Wire.payload(state)),
            createdAt: 1_000
        ))
        let wire = try #require(try? result.get())
        #expect(wire.entity == "queue_state")
        #expect(wire.entityId == "phone")
    }

    /// A newer client's extra column is not an error. Unknown keys ride along
    /// untouched, so adding one needs no server deploy and no coordinated release.
    @Test("an unrecognised column in the payload is carried, not refused")
    func unknownColumnsSurvive() throws {
        var fields = try #require(try Wire.payload(makePlaylist(updatedAt: 1, device: "mac")).objectValue)
        fields["colourTheme"] = .string("dusk")
        let result = WireOp.make(from: try op(payload: try Wire.text(.object(fields))))
        let wire = try #require(try? result.get())
        #expect(wire.payload.objectValue?["colourTheme"]?.stringValue == "dusk")
    }

    // MARK: - Refusals

    /// The track cache is never synced, and the enum has no case for it, so this is
    /// the only outcome available.
    @Test("an op for the track cache can never reach the wire")
    func trackIsRefused() throws {
        #expect(fault(WireOp.make(from: try op(entity: "track"))) == .unknownEntity("track"))
    }

    @Test("an entity this build does not know is refused")
    func unknownEntity() throws {
        #expect(fault(WireOp.make(from: try op(entity: "download"))) == .unknownEntity("download"))
    }

    /// The server matches operations case-sensitively, and `Op` stores the string
    /// rather than the enum, so a row written by anything else can hold anything.
    @Test("an operation the server would not match is refused")
    func badOperation() throws {
        var raw = try op()
        raw.operation = "UPSERT"
        #expect(fault(WireOp.make(from: raw)) == .unknownOperation("UPSERT"))
    }

    /// The invariant nothing upstream can check: the server never parses payloads,
    /// so a disagreement here syncs happily and confuses every reader afterwards.
    @Test("an entity id that disagrees with the payload is refused")
    func identityMismatch() throws {
        let raw = try op(entityId: "list-1")
        var mismatched = raw
        mismatched.entityId = "list-2"
        #expect(
            fault(WireOp.make(from: mismatched))
                == .identityMismatch(entityId: "list-2", payloadId: "list-1")
        )
    }

    @Test("a payload with no identity field at all is refused")
    func missingIdentity() throws {
        let result = WireOp.make(from: try op(payload: #"{"name":"Late Night"}"#))
        #expect(fault(result) == .identityMismatch(entityId: "list-1", payloadId: nil))
    }

    @Test("a payload that is not a JSON object is refused")
    func payloadShapes() throws {
        #expect(fault(WireOp.make(from: try op(payload: "[1,2,3]"))) == .payloadNotAnObject)
        #expect(fault(WireOp.make(from: try op(payload: "\"a string\""))) == .payloadNotAnObject)
        #expect(fault(WireOp.make(from: try op(payload: "not json at all"))) == .payloadNotAnObject)
        #expect(fault(WireOp.make(from: try op(payload: ""))) == .payloadNotAnObject)
    }

    @Test("a payload over the server's limit is refused before it is sent")
    func oversizedPayload() throws {
        var list = makePlaylist(updatedAt: 1, device: "phone")
        list.notes = String(repeating: "x", count: 300 * 1024)
        let raw = try op(payload: try Wire.text(Wire.payload(list)))
        #expect(fault(WireOp.make(from: raw))?.reason.contains("payload is") == true)
        guard case .payloadTooLarge(let bytes)? = fault(WireOp.make(from: raw)) else {
            Issue.record("expected an oversized payload")
            return
        }
        #expect(bytes > SyncPolicy.maxPayloadBytes)
    }

    @Test("ids outside the server's bounds are refused")
    func idBounds() throws {
        #expect(fault(WireOp.make(from: try op(opId: ""))) == .emptyOpId)
        #expect(fault(WireOp.make(from: try op(opId: String(repeating: "a", count: 129)))) == .opIdTooLong(129))
        #expect(fault(WireOp.make(from: try op(entityId: ""))) == .emptyEntityId)

        let longId = String(repeating: "b", count: 257)
        var raw = try op()
        raw.entityId = longId
        #expect(fault(WireOp.make(from: raw)) == .entityIdTooLong(257))
    }

    @Test("a timestamp the server would not accept is refused")
    func badTimestamp() throws {
        #expect(fault(WireOp.make(from: try op(createdAt: 0))) == .nonPositiveTimestamp(0))
        #expect(fault(WireOp.make(from: try op(createdAt: -5))) == .nonPositiveTimestamp(-5))
    }

    /// A delete whose payload does not say so travels as a live row and resurrects
    /// itself on every device that merges it.
    @Test("a delete must carry the flag in its payload")
    func deleteNeedsItsFlag() throws {
        let alive = try Wire.text(Wire.payload(makePlaylist(updatedAt: 1, device: "phone")))
        #expect(fault(WireOp.make(from: try op(operation: .delete, payload: alive))) == .deleteWithoutFlag)

        let dead = try Wire.text(Wire.payload(makePlaylist(updatedAt: 1, deleted: true, device: "phone")))
        #expect(fault(WireOp.make(from: try op(operation: .delete, payload: dead))) == nil)
    }

    /// The contract writes the invariant as `deleted = 1`, this app encodes a Swift
    /// `Bool`, and nothing between the two normalises it.
    @Test("the delete flag reads as set whether it is spelled true or 1")
    func deleteFlagSpellings() throws {
        for spelling in ["true", "1"] {
            let payload = #"{"deleted":\#(spelling),"id":"list-1","name":"x","originDevice":"p","sortIndex":"V","updatedAt":1}"#
            #expect(fault(WireOp.make(from: try op(operation: .delete, payload: payload))) == nil)
        }
        let unset = #"{"deleted":0,"id":"list-1","name":"x","originDevice":"p","sortIndex":"V","updatedAt":1}"#
        #expect(fault(WireOp.make(from: try op(operation: .delete, payload: unset))) == .deleteWithoutFlag)
    }

    // MARK: - Envelopes

    @Test("a push request encodes the shape the contract documents")
    func pushRequestShape() throws {
        let wire = try #require(try? WireOp.make(from: try op(opId: "op-1")).get())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(PushRequest(deviceId: "phone", ops: [wire])), as: UTF8.self)

        #expect(json.contains(#""deviceId":"phone""#))
        #expect(json.contains(#""opId":"op-1""#))
        #expect(json.contains(#""entity":"playlists""#))
        #expect(json.contains(#""operation":"upsert""#))
        #expect(json.contains(#""createdAt":1700000000000"#))
        // The payload is an object, not the string it is stored as.
        #expect(json.contains(#""payload":{"#))
    }

    @Test("a push response decodes, rejections and all")
    func pushResponseDecodes() throws {
        let json = #"{"accepted":["a","b"],"rejected":[{"opId":"c","reason":"bad entity"}],"cursor":12345}"#
        let response = try JSONDecoder().decode(PushResponse.self, from: Data(json.utf8))
        #expect(response.accepted == ["a", "b"])
        #expect(response.rejected == [RejectedOp(opId: "c", reason: "bad entity")])
        #expect(response.cursor == PushCursor(12345))
    }

    /// The original design document has no `rejected` field at all, and the contract
    /// describes it in prose. Failing the whole response over its shape would throw
    /// away the `accepted` list sitting beside it.
    @Test("a push response survives a rejected list in an unexpected shape")
    func pushResponseTolerance() throws {
        let missing = #"{"accepted":["a"],"cursor":7}"#
        #expect(try JSONDecoder().decode(PushResponse.self, from: Data(missing.utf8)).rejected.isEmpty)

        let bare = #"{"accepted":[],"rejected":["c"],"cursor":7}"#
        let decoded = try JSONDecoder().decode(PushResponse.self, from: Data(bare.utf8))
        #expect(decoded.rejected.map(\.opId) == ["c"])
    }

    /// Nothing reads the push cursor — it is the server's head, not this device's read
    /// position. Requiring it would mean a reply that omitted it threw away the
    /// `accepted` list beside it, so every op in that batch would be pushed again
    /// forever over a field the client has already decided to ignore.
    @Test("a push response without a cursor still acknowledges its ops")
    func pushResponseWithoutCursor() throws {
        let json = #"{"accepted":["a","b"]}"#
        let response = try JSONDecoder().decode(PushResponse.self, from: Data(json.utf8))
        #expect(response.accepted == ["a", "b"])
        #expect(response.cursor == nil)
    }

    @Test("a pull response decodes with the three fields the server adds")
    func pullResponseDecodes() throws {
        let json = """
        {"ops":[{"opId":"o1","entity":"playlists","entityId":"l1","operation":"upsert",
        "payload":{"id":"l1"},"createdAt":1754500000000,"seq":42,"deviceId":"mac",
        "receivedAt":1754500000500}],"cursor":12400,"hasMore":true}
        """
        let response = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        #expect(response.cursor == PullCursor(12400))
        #expect(response.hasMore)
        #expect(response.ops.count == 1)
        #expect(response.ops[0].seq == 42)
        #expect(response.ops[0].deviceId == "mac")
        #expect(response.ops[0].receivedAt == 1_754_500_000_500)
        #expect(response.unreadableOps == 0)
    }

    /// One unreadable entry costs the batch, and the batch is every future batch: the
    /// cursor only advances inside the transaction that applies one, so a response that
    /// throws is requested again, throws again, and inbound sync stops for good while
    /// push carries on working — divergence in one direction that looks like a flaky
    /// connection.
    @Test("one unreadable op does not cost the rest of the batch")
    func pullResponseSkipsUnreadableOps() throws {
        let json = """
        {"ops":[
        {"opId":"o1","entity":"playlists","entityId":"l1","operation":"upsert",
        "payload":{"id":"l1"},"createdAt":1,"seq":1,"deviceId":"mac","receivedAt":2},
        {"opId":"o2","entity":"playlists","seq":2},
        {"opId":"o3","entity":"playlists","entityId":"l3","operation":"upsert",
        "payload":{"id":"l3"},"createdAt":1,"seq":3,"deviceId":"mac","receivedAt":2}
        ],"cursor":3,"hasMore":false}
        """
        let response = try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8))
        #expect(response.ops.map(\.opId) == ["o1", "o3"])
        #expect(response.unreadableOps == 1)
        #expect(response.cursor == PullCursor(3))
    }

    @Test("cursors are bare integers on the wire")
    func cursorCoding() throws {
        #expect(try JSONDecoder().decode(PullCursor.self, from: Data("99".utf8)) == PullCursor(99))
        #expect(try JSONDecoder().decode(PushCursor.self, from: Data("99".utf8)) == PushCursor(99))
        #expect(String(decoding: try JSONEncoder().encode(PullCursor(99)), as: UTF8.self) == "99")
    }

    @Test("the pull cursor round-trips through the store")
    func storedCursor() throws {
        let store = try CurationStore.inMemory(deviceId: "phone")
        #expect(try store.pullCursor() == nil)
        try store.setSyncCursor("4200")
        #expect(try store.pullCursor() == PullCursor(4200))
    }

    // MARK: - JSON model

    @Test("payload JSON survives a round trip without changing type")
    func jsonRoundTrip() throws {
        let original: JSONValue = .object([
            "id": .string("x"),
            "updatedAt": .int(1_754_500_000_000),
            "deleted": .bool(false),
            "ratio": .double(0.5),
            "notes": .null,
            "tags": .array([.string("a"), .int(2)])
        ])
        let text = try Wire.text(original)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == original)
    }

    /// Every conflict in the system is decided by comparing two of these, so a
    /// millisecond timestamp that went through a `Double` on the way in would be a
    /// silent source of wrong winners.
    @Test("a millisecond timestamp stays an integer")
    func timestampsStayIntegers() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"t":1754500000123}"#.utf8))
        #expect(decoded.objectValue?["t"] == .int(1_754_500_000_123))
    }

    @Test("a boolean does not arrive as a number")
    func booleansStayBooleans() throws {
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"deleted":true}"#.utf8))
        #expect(decoded.objectValue?["deleted"] == .bool(true))
    }
}
