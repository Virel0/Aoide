import MeleteKit
import SwiftUI

/// Groups items into the A–Z sections a long list needs to be navigable.
enum AlphabetSections {
    struct Section: Identifiable {
        let id: String
        let items: [MusicItem]
    }

    /// `#` collects everything that doesn't start with a letter — numbers, symbols,
    /// and non-Latin scripts. Apple Music does the same, and a personal library
    /// always has some.
    static let symbolKey = "#"

    static func group(_ items: [MusicItem]) -> [Section] {
        var order: [String] = []
        var buckets: [String: [MusicItem]] = [:]

        for item in items {
            let key = key(for: item.name)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(item)
        }
        // Preserve the server's ordering rather than re-sorting: it already applied
        // the sort the user chose, which may not be alphabetical at all.
        return order.map { Section(id: $0, items: buckets[$0] ?? []) }
    }

    static func key(for name: String) -> String {
        // Fold accents so "Ólafur" files under O rather than in the symbol bucket.
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let first = folded.first(where: { !$0.isWhitespace }) else { return symbolKey }
        return first.isLetter ? String(first).uppercased() : symbolKey
    }
}

/// The letter rail down the right edge.
///
/// Built by hand because SwiftUI has no section-index API — and without one, the
/// only way through a few thousand artists is to scroll for a minute.
struct AlphabetIndexBar: View {
    let sections: [String]
    let onSelect: (String) -> Void

    @State private var isDragging = false
    @GestureState private var dragLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height / CGFloat(max(sections.count, 1))

            VStack(spacing: 0) {
                ForEach(sections, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, minHeight: height)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = Int(value.location.y / max(height, 1))
                        guard sections.indices.contains(index) else { return }
                        if !isDragging {
                            isDragging = true
                        }
                        select(sections[index])
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastSelected = nil
                    }
            )
        }
        .frame(width: 22)
        .padding(.vertical, 4)
        // The rail is a convenience for sighted scrolling; VoiceOver has the
        // rotor and the section headers, and reading 27 letters aloud is noise.
        .accessibilityHidden(true)
    }

    @State private var lastSelected: String?

    private func select(_ letter: String) {
        guard letter != lastSelected else { return }
        lastSelected = letter
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onSelect(letter)
    }
}

/// A list that carries an A–Z rail, used by Artists and Songs.
struct AlphabetIndexedList<Row: View>: View {
    let sections: [AlphabetSections.Section]
    @ViewBuilder var row: (MusicItem) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .trailing) {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                row(item)
                            }
                        } header: {
                            Text(section.id)
                        }
                        .id(section.id)
                    }
                }
                .listStyle(.plain)

                if sections.count > 3 {
                    AlphabetIndexBar(sections: sections.map(\.id)) { letter in
                        withAnimation(.none) {
                            proxy.scrollTo(letter, anchor: .top)
                        }
                    }
                    .padding(.trailing, 2)
                }
            }
        }
    }
}
