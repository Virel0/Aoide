import Foundation
import Testing
@testable import CurationKit

@Suite("Discover, as the client reads it")
struct DiscoverTests {
    @Test("The answer decodes with the seed-only factors sent as null")
    func decodes() throws {
        let data = Data("""
        { "week": "2026-W43",
          "candidates": [
            { "id": "a", "score": 0.75,
              "factors": { "taste": 0.75, "kinship": null, "freshness": 1, "similarity": null, "mixability": null, "arc": null } }
          ],
          "profile": { "events": 184, "since": 1784592000000 } }
        """.utf8)
        let response = try Discover.decode(data)
        #expect(response.week == "2026-W43")
        #expect(response.candidates.map(\.id) == ["a"])
        #expect(response.candidates[0].taste == 0.75)
        #expect(response.profile.events == 184)
    }

    @Test("The week is ISO and UTC, and turns at Monday 00:00 UTC")
    func week() throws {
        let utc = { (s: String) in try #require(ISO8601DateFormatter().date(from: s)) }
        // Sunday 23:59:59 UTC is still the old week; a second later is the new one.
        #expect(Discover.week(of: try utc("2026-10-25T23:59:59Z")) == "2026-W43")
        #expect(Discover.week(of: try utc("2026-10-26T00:00:00Z")) == "2026-W44")
        // Across New Year: 2027-01-01 is a Friday in ISO week 53 of 2026.
        #expect(Discover.week(of: try utc("2027-01-01T12:00:00Z")) == "2026-W53")
        #expect(Discover.week(of: try utc("2027-01-04T00:00:00Z")) == "2027-W01")
    }

    @Test("Every week name in the sidecar's fixture table, the same here")
    func sidecarWeeks() {
        // Copied from the sidecar's discover-fixture.json, "weeks".
        let rows: [(Int64, String)] = [
            (1792368000000, "2026-W43"),
            (1792367999999, "2026-W42"),
            (1767225600000, "2026-W01"),
            (1798718400000, "2026-W53"),
            (1799020799999, "2026-W53"),
            (1799020800000, "2027-W01"),
            (1735516800000, "2025-W01"),
        ]
        for (ms, week) in rows {
            #expect(Discover.week(of: Date(timeIntervalSince1970: Double(ms) / 1_000)) == week, "\(ms)")
        }
    }
}
