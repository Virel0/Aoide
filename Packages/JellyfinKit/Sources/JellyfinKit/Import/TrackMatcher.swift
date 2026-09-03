import Foundation

/// Decides whether a library track is the one a playlist meant.
///
/// The imported side has a title, some artist names and a length; the library side
/// has the same three from its own tags, spelled by different people. The rules
/// here are written down as a specification because the desktop app carries the
/// **same rules in TypeScript**, and both are checked against one table of cases:
/// a track that matches on the phone must match on the desk, or an import made on
/// one would disagree with the other about what is missing.
///
/// Normalisation, in order:
/// 1. lower-case, then fold diacritics ("Beyoncé" → "beyonce");
/// 2. "&" → " and ";
/// 3. drop a bracketed group — `(…)` or `[…]` — whose text contains a noise word;
/// 4. drop a ` - …` suffix whose text contains a noise word;
/// 5. keep only letters, digits and spaces; collapse runs of spaces; trim.
///
/// Noise words: feat, ft, featuring, with, remaster, remastered, remix, mix,
/// version, edit, live, mono, stereo, deluxe, anniversary, bonus, explicit,
/// clean, radio, single, demo, acoustic, instrumental, from, original, edition.
///
/// Scores (0…1), each from the two normalised strings' word sets:
/// - equal → 1; one's words all inside the other's → 0.9; otherwise the Jaccard
///   overlap (shared ÷ union).
/// - title uses the best of those; artist uses the best over every pair of
///   imported artist × library artist (album artist included).
/// - duration, when both known: within 5 s → 1; within 15 s → 0.8; else 0.
///   Unknown on either side → 0.9.
///
/// A candidate is accepted when title ≥ 0.75, artist ≥ 0.7 and duration > 0; the
/// overall score, used only to rank accepted candidates, is
/// 0.5·title + 0.35·artist + 0.15·duration. A library track with no artist at all
/// scores 0.5 on artist, so it is accepted only when the title is exact.
public enum TrackMatcher {
    public struct Candidate: Sendable, Equatable {
        public var title: String
        public var artists: [String]
        public var durationMs: Int?
        public init(title: String, artists: [String], durationMs: Int?) {
            self.title = title
            self.artists = artists
            self.durationMs = durationMs
        }
    }

    public struct Verdict: Sendable, Equatable {
        public var title: Double
        public var artist: Double
        public var duration: Double
        public var isAccepted: Bool
        public var overall: Double
    }

    public static let titleThreshold = 0.75
    public static let artistThreshold = 0.7
    public static let closeDurationMs = 5_000
    public static let looseDurationMs = 15_000

    static let noiseWords: Set<String> = [
        "feat", "ft", "featuring", "with", "remaster", "remastered", "remix", "mix",
        "version", "edit", "live", "mono", "stereo", "deluxe", "anniversary", "bonus",
        "explicit", "clean", "radio", "single", "demo", "acoustic", "instrumental",
        "from", "original", "edition",
    ]

    public static func verdict(for track: ImportedTrack, against candidate: Candidate) -> Verdict {
        let title = similarity(normalize(track.title), normalize(candidate.title))

        let artist: Double
        if candidate.artists.isEmpty || track.artists.isEmpty {
            artist = 0.5
        } else {
            let ours = track.artists.map(normalize)
            let theirs = candidate.artists.map(normalize)
            artist = ours.flatMap { a in theirs.map { similarity(a, $0) } }.max() ?? 0
        }

        let duration: Double
        if let a = track.durationMs, let b = candidate.durationMs {
            let delta = abs(a - b)
            duration = delta <= closeDurationMs ? 1 : (delta <= looseDurationMs ? 0.8 : 0)
        } else {
            duration = 0.9
        }

        // With no artist to compare, only an exact title is trusted.
        let artistAccepted = (candidate.artists.isEmpty || track.artists.isEmpty)
            ? title == 1
            : artist >= artistThreshold
        let isAccepted = title >= titleThreshold && artistAccepted && duration > 0

        return Verdict(
            title: title, artist: artist, duration: duration,
            isAccepted: isAccepted,
            overall: 0.5 * title + 0.35 * artist + 0.15 * duration
        )
    }

    /// The best accepted candidate's index, or nil when none is the track.
    public static func best(for track: ImportedTrack, among candidates: [Candidate]) -> Int? {
        var bestIndex: Int?
        var bestScore = -1.0
        for (index, candidate) in candidates.enumerated() {
            let verdict = verdict(for: track, against: candidate)
            guard verdict.isAccepted, verdict.overall > bestScore else { continue }
            bestScore = verdict.overall
            bestIndex = index
        }
        return bestIndex
    }

    // MARK: - Specification

    public static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        s = s.replacingOccurrences(of: "&", with: " and ")

        s = stripNoisyGroups(s, open: "(", close: ")")
        s = stripNoisyGroups(s, open: "[", close: "]")
        s = stripNoisySuffix(s)

        let kept = s.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        guard a == b else {
            let wordsA = Set(a.split(separator: " "))
            let wordsB = Set(b.split(separator: " "))
            guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
            if wordsA.isSubset(of: wordsB) || wordsB.isSubset(of: wordsA) { return 0.9 }
            let shared = wordsA.intersection(wordsB).count
            let union = wordsA.union(wordsB).count
            return Double(shared) / Double(union)
        }
        return a.isEmpty ? 0 : 1
    }

    private static func containsNoise(_ text: Substring) -> Bool {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .contains { noiseWords.contains(String($0)) }
    }

    private static func stripNoisyGroups(_ text: String, open: Character, close: Character) -> String {
        var result = text
        while let start = result.firstIndex(of: open),
              let end = result[start...].firstIndex(of: close) {
            let inside = result[result.index(after: start)..<end]
            if containsNoise(inside) {
                result.removeSubrange(start...end)
            } else {
                // A group worth keeping — "(What's the Story) Morning Glory?" —
                // stays, brackets and all; the bracket characters go later.
                var kept = result
                kept.replaceSubrange(start...end, with: " \(inside) ")
                result = kept
            }
        }
        return result
    }

    private static func stripNoisySuffix(_ text: String) -> String {
        guard let range = text.range(of: " - ") else { return text }
        let suffix = text[range.upperBound...]
        return containsNoise(suffix) ? String(text[..<range.lowerBound]) : text
    }
}
