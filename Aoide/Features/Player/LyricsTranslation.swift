import MeleteKit
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

/// Lyrics in the listener's own language, under the original lines.
///
/// On-device, through Apple's Translation framework: nothing is sent anywhere,
/// and a language pair is downloaded once, by the system, the first time it is
/// asked for. Offered only when the lyrics are not already in the listener's
/// language — a button that translates English into English is noise.
@MainActor
@Observable
final class LyricsTranslation {
    /// Whether the listener wants translations shown, kept between launches.
    var isOn: Bool = UserDefaults.standard.bool(forKey: LyricsTranslation.key) {
        didSet { UserDefaults.standard.set(isOn, forKey: Self.key) }
    }

    /// Translated text by line id, per track.
    private(set) var lines: [String: [Int: String]] = [:]
    /// Why the last translation failed, if it did — shown, not hidden.
    private(set) var problem: String?

    static let key = "aoide.lyrics.translate"

    /// The listener's language, which is what everything is translated into.
    nonisolated static var target: Locale.Language { Locale.current.language }

    /// The language the lyrics are in, if it can be told, by the system's own
    /// recogniser over the whole text.
    nonisolated static func language(of lyrics: LyricsTrack) -> Locale.Language? {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(lyrics.plainText)
        guard let dominant = recogniser.dominantLanguage, dominant != .undetermined else { return nil }
        return Locale.Language(identifier: dominant.rawValue)
    }

    /// Whether these lyrics are in some other language than the listener's.
    nonisolated static func isForeign(_ lyrics: LyricsTrack) -> Bool {
        guard let source = language(of: lyrics) else { return false }
        return source.languageCode != target.languageCode
    }

    func translations(for trackId: String) -> [Int: String]? { lines[trackId] }

    func needsTranslation(_ trackId: String) -> Bool { lines[trackId] == nil }

    func store(_ translated: [Int: String], for trackId: String) {
        lines[trackId] = translated
        problem = nil
    }

    func fail(_ error: Error) {
        problem = error.localizedDescription
    }

    /// What to send for `lyrics`: every non-empty line, tagged with its id.
    nonisolated static func requests(for lyrics: LyricsTrack) -> [TranslationSession.Request] {
        lyrics.lines
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: String($0.id)) }
    }

    /// The answers, back by line id.
    nonisolated static func byLine(_ responses: [TranslationSession.Response]) -> [Int: String] {
        var translated: [Int: String] = [:]
        for response in responses {
            guard let id = response.clientIdentifier.flatMap(Int.init) else { continue }
            translated[id] = response.targetText
        }
        return translated
    }
}
