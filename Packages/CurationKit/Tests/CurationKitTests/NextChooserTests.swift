import Foundation
import Testing
@testable import CurationKit

@Suite("Asking the server what plays next")
struct NextChooserTests {
    @Test("The request is the contract's shape, with the mode spelled as the server expects")
    func requestShape() throws {
        let request = NextChooser.Request(seed: "s", queue: ["q1", "q2"], recent: ["r1"], mode: .autodj, limit: 20)
        let json = try #require(try JSONSerialization.jsonObject(with: NextChooser.encode(request)) as? [String: Any])
        #expect(json["seed"] as? String == "s")
        #expect(json["queue"] as? [String] == ["q1", "q2"])
        #expect(json["recent"] as? [String] == ["r1"])
        #expect(json["mode"] as? String == "autodj")
        #expect(json["limit"] as? Int == 20)
        #expect(NextChooser.Mode.infinity.rawValue == "infinity")
    }

    @Test("A long queue and a long history are cut from the far end, not refused")
    func ceilings() {
        let queue = (0..<1200).map { "q\($0)" }
        let recent = (0..<60).map { "r\($0)" }
        let request = NextChooser.Request(seed: "s", queue: queue, recent: recent, mode: .infinity, limit: 20)
        #expect(request.queue.count == 1000)
        #expect(request.queue.first == "q0")
        #expect(request.queue.last == "q999")
        #expect(request.recent.count == 40)
        #expect(request.recent.first == "r0")
    }

    @Test("The answer decodes with mixability absent outside Auto DJ")
    func responseDecodes() throws {
        let data = Data("""
        { "candidates": [
            { "id": "a", "score": 0.83,
              "factors": { "taste": 0.71, "freshness": 1.0, "similarity": 0.62, "mixability": 0.79, "arc": 0.9 } },
            { "id": "b", "score": 0.4,
              "factors": { "taste": 0.2, "freshness": 0.5, "similarity": 0.5, "mixability": null, "arc": 0.5 } }
          ],
          "profile": { "events": 184, "since": 1749600000000 } }
        """.utf8)
        let response = try NextChooser.decode(data)
        #expect(response.candidates.map(\.id) == ["a", "b"])
        #expect(response.candidates[0].factors.mixability == 0.79)
        #expect(response.candidates[1].factors.mixability == nil)
        #expect(response.profile.events == 184)
        #expect(response.profile.since == 1_749_600_000_000)
    }

    @Test("The summary reads as percentages, names a mix only when there is one, and says what freshness cost")
    func summary() {
        let mixed = NextChooser.Factors(taste: 0.714, freshness: 1, similarity: 0.62, mixability: 0.79, arc: 0.9)
        #expect(mixed.summary == "Taste 71% · Fits 62% · Mixes 79% · Arc 90%")

        let unmixed = NextChooser.Factors(taste: 0.2, freshness: 1, similarity: 0.5, mixability: nil, arc: 0.5)
        #expect(unmixed.summary == "Taste 20% · Fits 50% · Arc 50%")

        let sameArtist = NextChooser.Factors(taste: 0.2, freshness: 0.5, similarity: 0.5, mixability: nil, arc: 0.5)
        #expect(sameArtist.summary.hasSuffix("· same artist lately"))

        let heard = NextChooser.Factors(taste: 0.2, freshness: 0, similarity: 0.5, mixability: nil, arc: 0.5)
        #expect(heard.summary.hasSuffix("· heard lately"))
    }
}
