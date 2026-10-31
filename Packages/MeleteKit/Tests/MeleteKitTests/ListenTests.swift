import Foundation
import Testing
@testable import MeleteKit

@Suite("Listening together")
struct ListenTests {
    private func session(_ queue: [Int64], index: Int, at position: Int64, playing: Bool) -> ListenSession {
        let json: [String: Any] = [
            "id": 1, "code": "ABC234", "host": "alice", "queue": queue, "index": index,
            "position_ms": position, "position_at": 10_000, "playing": playing, "version": 1,
            "members": [[String: Any]](),
        ]
        return try! JSONDecoder.melete.decode(ListenSession.self, from: Fixture.json(json))
    }

    private func local(_ ids: [String], index: Int, at position: Int64, playing: Bool) -> ListenLocal {
        ListenLocal(ids: ids, index: index, positionMs: position, playing: playing)
    }

    @Test("the position moves on only while playing, and never back")
    func position() {
        #expect(session([4], index: 0, at: 1_000, playing: true).position(at: 12_500) == 3_500)
        #expect(session([4], index: 0, at: 1_000, playing: false).position(at: 12_500) == 1_000)
        #expect(session([4], index: 0, at: 1_000, playing: true).position(at: 9_000) == 1_000)
    }

    @Test("a player where the session says, within the tolerance, is in step")
    func inStep() {
        let shared = session([4, 5], index: 1, at: 20_000, playing: true)
        #expect(ListenPlan(session: shared, local: local(["4", "5"], index: 1, at: 22_000, playing: true), serverNow: 12_000) == .nothing)
        #expect(ListenPlan(session: shared, local: local(["4", "5"], index: 1, at: 19_500, playing: true), serverNow: 12_000) == .nothing)
    }

    @Test("a different queue is rebuilt; the same one is jumped, sought, paused")
    func plans() {
        let shared = session([4, 5], index: 1, at: 1_000, playing: true)
        #expect(ListenPlan(session: shared, local: local(["5", "4"], index: 1, at: 0, playing: true), serverNow: 10_000) == .rebuild)
        #expect(
            ListenPlan(session: shared, local: local(["4", "5"], index: 0, at: 60_000, playing: true), serverNow: 10_500)
                == .adjust(jump: 1, seek: 1_500, play: nil)
        )
        let paused = session([4, 5], index: 0, at: 30_000, playing: false)
        #expect(
            ListenPlan(session: paused, local: local(["4", "5"], index: 0, at: 40_000, playing: true), serverNow: 99_000)
                == .adjust(jump: nil, seek: 30_000, play: false)
        )
        #expect(ListenPlan(session: session([], index: 0, at: 0, playing: false), local: local([], index: 0, at: 0, playing: true), serverNow: 0) == .nothing)
    }

    @Test("only Melete's number ids can be sent")
    func state() {
        #expect(local(["4", "5"], index: 1, at: 1_200, playing: true).state == ListenState(queue: [4, 5], index: 1, positionMs: 1_200, playing: true))
        #expect(local(["4", "a-file"], index: 0, at: 0, playing: true).state == nil)
    }

    private static func answer() -> Data {
        Fixture.json([
        "session": [
            "id": 7, "code": "ABC234", "host": "alice", "queue": [4, 5], "index": 1,
            "position_ms": 2_500, "position_at": 1_000_000, "playing": true, "version": 3,
            "members": [
                ["username": "alice", "device": "Desk", "you": false],
                ["username": "alice", "device": "Phone", "you": true],
            ],
        ],
        "server_time": 1_000_400,
        ])
    }

    @Test("start, join, change, leave and end go where Melete has them")
    func requests() async throws {
        let client = StubServer.client(host: "listen.test") { request, body in
            let sent = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            switch (request.httpMethod, request.url?.path()) {
            case ("POST", "/api/v1/music/sessions"):
                return sent?["position_ms"] as? Int == 2_500 ? (201, Self.answer()) : (400, Data())
            case ("POST", "/api/v1/music/sessions/join"):
                return sent?["code"] as? String == "abc-234"
                    ? (200, Self.answer())
                    : (404, Fixture.json(["error": "no session has that code"]))
            case ("PUT", "/api/v1/music/sessions/7"):
                return sent?["version"] as? Int == 3
                    ? (200, Self.answer())
                    : (409, Fixture.json(["error": "it changed since"]))
            case ("POST", "/api/v1/music/sessions/7/leave"), ("DELETE", "/api/v1/music/sessions/7"):
                return (204, Data())
            default:
                return (404, Data())
            }
        }
        let state = ListenState(queue: [4, 5], index: 1, positionMs: 2_500, playing: true)
        let started = try await client.startListening(state)
        #expect(started.session.code == "ABC234" && started.serverTime == 1_000_400)
        #expect(started.session.members.map(\.you) == [false, true])
        #expect(try await client.joinListening(code: "abc-234").session.id == 7)
        await #expect(throws: MeleteError.notFound(path: "api/v1/music/sessions/join")) {
            try await client.joinListening(code: "ZZZ999")
        }
        #expect(try await client.changeListening(id: 7, version: 3, state: state).session.version == 3)
        do {
            _ = try await client.changeListening(id: 7, version: 2, state: state)
            Issue.record("a stale change was accepted")
        } catch let error as MeleteError {
            #expect(error.isStale)
        }
        try await client.leaveListening(id: 7)
        try await client.endListening(id: 7)
        #expect(!MeleteError.notFound(path: "").isStale)
    }
}
