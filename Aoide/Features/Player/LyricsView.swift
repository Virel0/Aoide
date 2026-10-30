import MeleteKit
import PlaybackKit
import SwiftUI
@preconcurrency import Translation

/// Apple Music-style lyrics: the current line in full strength, the rest dimmed,
/// scrolling itself and seekable by tap.
struct LyricsView: View {
    @Environment(LyricsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var engine = PlaybackEngine.shared
    @State private var activeLine: Int?
    /// Suspends auto-scroll while the user is reading ahead, then resumes.
    @State private var isUserScrolling = false
    @State private var resumeTask: Task<Void, Never>?
    @State private var isShowingOffset = false
    @State private var translation = LyricsTranslation()
    /// Set when there is something to translate; the framework runs the task
    /// whenever this changes, and asks to download the language pair the
    /// first time.
    @State private var translationRequest: TranslationSession.Configuration?

    private var trackId: String? { engine.currentTrack?.id }

    var body: some View {
        NavigationStack {
            Group {
                switch trackId.flatMap({ store.entry(for: $0) }) {
                case .loaded(let lyrics):
                    content(lyrics)
                case .loading, .none:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .absent:
                    ContentUnavailableView(
                        "No Lyrics",
                        systemImage: "quote.bubble",
                        description: Text("This track doesn't have a lyrics file on your server.")
                    )
                case .failed(let message):
                    ContentUnavailableView(
                        "Couldn't Load Lyrics",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle(engine.currentTrack?.title ?? "Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Timing", systemImage: "slider.horizontal.3") {
                        isShowingOffset = true
                    }
                }
                if let lyrics = loadedLyrics, LyricsTranslation.isForeign(lyrics) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(
                            translation.isOn ? "Hide Translation" : "Translate",
                            systemImage: "translate"
                        ) {
                            translation.isOn.toggle()
                        }
                        .symbolVariant(translation.isOn ? .fill : .none)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: translationKey, initial: true) {
                guard translation.isOn, let lyrics = loadedLyrics, LyricsTranslation.isForeign(lyrics) else {
                    translationRequest = nil
                    return
                }
                translationRequest = TranslationSession.Configuration(
                    source: LyricsTranslation.language(of: lyrics),
                    target: LyricsTranslation.target
                )
            }
            .translationTask(translationRequest) { session in
                guard let trackId, let lyrics = loadedLyrics, translation.needsTranslation(trackId) else { return }
                let requests = LyricsTranslation.requests(for: lyrics)
                guard !requests.isEmpty else { return }
                do {
                    // Called here, on the session the framework handed this
                    // closure: the session may not be passed anywhere else.
                    let responses = try await session.translations(from: requests)
                    translation.store(LyricsTranslation.byLine(responses), for: trackId)
                } catch {
                    translation.fail(error)
                }
            }
            .sheet(isPresented: $isShowingOffset) {
                LyricsOffsetSheet()
                    .environment(store)
                    .presentationDetents([.height(240)])
            }
        }
        .task(id: trackId) {
            guard let trackId else { return }
            await store.load(trackId: trackId)
            await store.prefetchUpNext()
        }
    }

    private var loadedLyrics: LyricsTrack? {
        guard let trackId, case .loaded(let lyrics) = store.entry(for: trackId) else { return nil }
        return lyrics
    }

    /// What a translation depends on: the track, whether its lyrics have
    /// arrived, and whether translations are wanted.
    private var translationKey: String {
        "\(trackId ?? "")|\(loadedLyrics != nil)|\(translation.isOn)"
    }

    /// The translated lines for the track playing, when they are wanted.
    private var shownTranslations: [Int: String] {
        guard translation.isOn, let trackId else { return [:] }
        return translation.translations(for: trackId) ?? [:]
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ lyrics: LyricsTrack) -> some View {
        if lyrics.isSynced {
            syncedLines(lyrics)
        } else {
            // A plain-text lyric file carries no timings, so there is nothing to
            // follow — show it as a readable block rather than faking a highlight.
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lyrics.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.title3.weight(.medium))
                        if let translated = shownTranslations[line.id] {
                            Text(translated)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
    }

    private func syncedLines(_ lyrics: LyricsTrack) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lyrics.lines) { line in
                        LyricLineView(line: line, translation: shownTranslations[line.id], isActive: line.id == activeLine)
                            .id(line.id)
                            .contentShape(.rect)
                            .onTapGesture {
                                guard let start = line.start else { return }
                                engine.seek(to: start)
                                activeLine = line.id
                                isUserScrolling = false
                                scroll(proxy, to: line.id)
                            }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    isUserScrolling = true
                    resumeTask?.cancel()
                } else if phase == .idle, isUserScrolling {
                    // Give the user a moment to read before snatching the view back.
                    resumeTask?.cancel()
                    resumeTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled else { return }
                        isUserScrolling = false
                        if let activeLine { scroll(proxy, to: activeLine) }
                    }
                }
            }
            .task(id: trackId) {
                await follow(lyrics, proxy: proxy)
            }
            .onChange(of: activeLine) { _, new in
                guard let new, !isUserScrolling else { return }
                scroll(proxy, to: new)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to line: Int) {
        withAnimation(.easeInOut(duration: 0.35)) {
            // Slightly above centre, so the next lines are readable — the same
            // placement Apple Music uses.
            proxy.scrollTo(line, anchor: UnitPoint(x: 0.5, y: 0.32))
        }
    }

    /// Advances the highlight.
    ///
    /// Sleeps until the next line is actually due rather than polling, because the
    /// start times are known exactly. Polling at display rate to re-check a value
    /// that changes a handful of times a minute would burn battery with the screen
    /// off for no benefit.
    private func follow(_ lyrics: LyricsTrack, proxy: ScrollViewProxy) async {
        while !Task.isCancelled {
            guard let now = engine.audibleElapsed else {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }

            let index = lyrics.index(at: now)
            if index != activeLine { activeLine = index }

            // How long until the following line begins.
            let nextStart = lyrics.lines
                .dropFirst((index ?? -1) + 1)
                .compactMap(\.start)
                .first

            let wait: Duration
            if let nextStart, nextStart > now {
                wait = min(nextStart - now, .seconds(2))
            } else {
                // Paused, seeking, or past the last line — check back lazily.
                wait = .milliseconds(400)
            }
            try? await Task.sleep(for: max(wait, .milliseconds(60)))
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    /// The line in the listener's language, under the original, when asked for.
    var translation: String? = nil
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.title2.weight(.semibold))
            if let translation {
                Text(translation)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .opacity(isActive ? 1 : 0.45)
        .scaleEffect(isActive ? 1.04 : 1, anchor: .leading)
        .blur(radius: isActive ? 0 : 0.6)
        .animation(.easeOut(duration: 0.25), value: isActive)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Manual timing nudge.
///
/// Automatic output-latency compensation gets close, but Bluetooth codecs
/// under-report their own delay and the error varies by headphone — so this has to
/// be adjustable by ear. Apple Music has the same control.
private struct LyricsOffsetSheet: View {
    @Environment(LyricsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Nudge the lyrics if they run ahead of or behind the music. Bluetooth headphones usually need a small adjustment.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text(label(for: store.offset))
                    .font(.title3.monospacedDigit().weight(.semibold))

                Slider(
                    value: Binding(
                        get: { store.offset.seconds },
                        set: { store.offset = .seconds($0) }
                    ),
                    in: -1.5...1.5,
                    step: 0.05
                ) {
                    Text("Lyrics timing")
                } minimumValueLabel: {
                    Text("Earlier").font(.caption2)
                } maximumValueLabel: {
                    Text("Later").font(.caption2)
                }

                Button("Reset") { store.offset = .zero }
                    .buttonStyle(.bordered)
                    .disabled(store.offset == .zero)
            }
            .padding(24)
            .navigationTitle("Lyrics Timing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func label(for offset: Duration) -> String {
        let ms = Int((offset.seconds * 1000).rounded())
        if ms == 0 { return "In sync" }
        return ms > 0 ? "\(ms) ms later" : "\(-ms) ms earlier"
    }
}
