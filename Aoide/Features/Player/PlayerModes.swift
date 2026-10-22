import CurationKit
import PlaybackKit
import SwiftUI

/// The things that stay on: Crossfade, Infinity, and what you are doing.
///
/// A row of their own, above the row you tap while a song plays. They are not
/// transport controls — you set one and it governs the next hour — and mixing
/// them in among shuffle, lyrics and AirPlay had eight identical grey glyphs
/// competing for one line, where the only way to know which was which was to
/// count.
///
/// Each one says its own name when it is on, which is the point: a mode left on
/// for a fortnight quietly colours everything, and a lit icon among seven others
/// is not a thing anybody notices.
struct PlayerModesRow: View {
    @AppStorage(CrossfadePreference.key) private var crossfade = false
    @AppStorage(AutoDJPreference.key) private var autoDJ = false
    @State private var infinity = InfinityQueue.shared
    @State private var activities = ActivityStore.shared

    var body: some View {
        HStack(spacing: 8) {
            ModeChip(
                title: "Crossfade",
                symbol: "arrow.triangle.merge",
                isOn: crossfade
            ) {
                crossfade.toggle()
                PlaybackEngine.shared.isCrossfading = crossfade
            }

            if AutoDJPreference.isAvailable {
                ModeChip(
                    title: "Auto DJ",
                    symbol: "slider.horizontal.3",
                    isOn: autoDJ,
                    icon: { Turntable(isSpinning: autoDJ, tint: autoDJ ? .accentColor : .secondary) }
                ) {
                    autoDJ.toggle()
                    PlaybackEngine.shared.isAutoDJing = autoDJ
                    if autoDJ {
                        BeatGridSync.shared.prefetch(ids: PlaybackEngine.shared.queue.entries.map(\.track.id))
                        ArrangementSync.shared.prefetch(ids: PlaybackEngine.shared.queue.entries.map(\.track.id))
                    }
                    infinity.autoDJChanged()
                }
            }

            ModeChip(
                title: "Infinity",
                symbol: "infinity",
                isOn: infinity.isOn
            ) {
                // Auto DJ has it on; tapping it does nothing until Auto DJ is
                // off, and the chip stays lit to say so.
                guard !AutoDJPreference.isOn else { return }
                infinity.setOn(!infinity.isChosen)
            }
            .opacity(AutoDJPreference.isOn ? 0.7 : 1)

            Menu {
                Button {
                    activities.set(nil)
                } label: {
                    Label("Not Set", systemImage: activities.current == nil ? "checkmark" : "minus")
                }
                Divider()
                ForEach(Activity.allCases, id: \.self) { activity in
                    Button {
                        activities.set(activity)
                    } label: {
                        Label(
                            activity.displayName,
                            systemImage: activities.current == activity ? "checkmark" : activity.symbolName
                        )
                    }
                }
            } label: {
                ModeChipLabel(
                    title: activities.current?.displayName ?? "Activity",
                    symbol: activities.current?.symbolName ?? "figure.walk.motion",
                    isOn: activities.current != nil
                )
            }
            .accessibilityLabel(activities.current.map { "Activity: \($0.displayName)" } ?? "Set activity")
        }
        .padding(.horizontal, 28)
    }
}

/// A capsule that is plainly off or plainly on.
///
/// Takes a drawn icon as well as a symbol name, because one of these is a
/// turntable and there is no turntable in SF Symbols.
struct ModeChip<Icon: View>: View {
    let title: String
    let symbol: String
    let isOn: Bool
    @ViewBuilder var icon: () -> Icon
    let toggle: () -> Void

    init(
        title: String,
        symbol: String,
        isOn: Bool,
        @ViewBuilder icon: @escaping () -> Icon = { EmptyView() },
        toggle: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.isOn = isOn
        self.icon = icon
        self.toggle = toggle
    }

    var body: some View {
        Button(action: toggle) {
            ModeChipLabel(title: title, symbol: symbol, isOn: isOn, icon: icon)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(isOn ? "on" : "off")")
    }
}

struct ModeChipLabel<Icon: View>: View {
    let title: String
    let symbol: String
    let isOn: Bool
    @ViewBuilder var icon: () -> Icon

    init(
        title: String,
        symbol: String,
        isOn: Bool,
        @ViewBuilder icon: @escaping () -> Icon = { EmptyView() }
    ) {
        self.title = title
        self.symbol = symbol
        self.isOn = isOn
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 5) {
            if Icon.self == EmptyView.self {
                Image(systemName: symbol)
            } else {
                icon().frame(width: 15, height: 15)
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background {
            Capsule().fill(isOn ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary))
        }
        .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}


/// What Auto DJ is doing, said out loud above the scrubber.
///
/// A mix and a long crossfade look identical from a scrubber, and the difference
/// is the entire feature — so the player says which it is, the way Apple Music's
/// own does. It also answers the question people actually have, which is not
/// "is it mixing" but "is it *going* to": a mix is booked half a minute before
/// anybody hears it, and that half minute is when somebody wonders.
///
/// Nothing at all when no hand-over is planned, or when the plan is a plain
/// join — a badge that says "no" or "gapless" on every track is a badge
/// nobody reads. A crossfade is named, with or without Auto DJ, so somebody
/// with both switches on can see which one is about to act.
struct MixBadge: View {
    let state: PlaybackEngine.MixState

    var body: some View {
        switch state {
        case .off, .ready:
            EmptyView()
        case .booked(let handOver):
            if let name = Self.name(handOver, live: false) {
                HStack(spacing: 6) {
                    Turntable(isSpinning: false, progress: 0.8, tint: .secondary)
                        .frame(width: 14, height: 14)
                    label("\(name) ready\(Self.length(handOver))", isLive: false)
                }
                .padding(.bottom, 6)
            }
        case .mixing(let handOver, let progress):
            if let name = Self.name(handOver, live: true) {
                VStack(spacing: 5) {
                    MixDecks(progress: progress)
                    label("\(name)\(Self.length(handOver))", isLive: true)
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
    }

    /// What to call it, or nothing for a join: "Gapless" on every album
    /// track is a badge nobody reads.
    private static func name(_ handOver: PlaybackEngine.HandOver, live: Bool) -> String? {
        switch handOver {
        case .mix(let style, _):
            switch style {
            case .blend: live ? "Mixing" : "Mix"
            case .filterFade: "Filter fade"
            case .cut: "Cut"
            case .echoOut: "Echo out"
            }
        case .crossfade: live ? "Crossfading" : "Crossfade"
        case .join: nil
        }
    }

    private static func length(_ handOver: PlaybackEngine.HandOver) -> String {
        switch handOver {
        case .mix(_, let bars): bars > 0 ? " · \(bars) bars" : ""
        case .crossfade(let seconds): " · \(Int(seconds.rounded())) s"
        case .join: ""
        }
    }

    private func label(_ title: String, isLive: Bool) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isLive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(isLive ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary))
            }
    }
}
