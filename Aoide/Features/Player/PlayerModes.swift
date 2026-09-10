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

            ModeChip(
                title: "Auto DJ",
                symbol: "slider.horizontal.3",
                isOn: autoDJ
            ) {
                autoDJ.toggle()
                PlaybackEngine.shared.isAutoDJing = autoDJ
                if autoDJ {
                    BeatGridSync.shared.prefetch(ids: PlaybackEngine.shared.queue.entries.map(\.track.id))
                }
            }

            ModeChip(
                title: "Infinity",
                symbol: "infinity",
                isOn: infinity.isOn
            ) {
                infinity.setOn(!infinity.isOn)
            }

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
struct ModeChip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ModeChipLabel(title: title, symbol: symbol, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(isOn ? "on" : "off")")
    }
}

struct ModeChipLabel: View {
    let title: String
    let symbol: String
    let isOn: Bool

    var body: some View {
        Label(title, systemImage: symbol)
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
