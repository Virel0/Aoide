import CurationKit
import Foundation
import SwiftUI

/// What the listener is doing right now, if they have said.
///
/// Device-local and never synced. The *tag on a play event* travels, because
/// play events do; the selection itself is about this device in this moment, and
/// a phone in a pocket adopting the desk's "Focus" would be nonsense.
///
/// Nothing detects it. A toggle somebody sets is honest; a guess from the time
/// of day would quietly mislabel the history that mixes and smart playlists are
/// later built from.
@MainActor
@Observable
final class ActivityStore {
    static let shared = ActivityStore()

    static let key = "aoide.currentActivity"

    private(set) var current: Activity?

    private init() {
        current = Activity.parse(UserDefaults.standard.string(forKey: Self.key))
    }

    func set(_ activity: Activity?) {
        current = activity
        if let activity {
            UserDefaults.standard.set(activity.rawValue, forKey: Self.key)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.key)
        }
    }
}

/// The picker, small enough to sit among the transport controls.
///
/// Shows the activity when one is set, so nobody leaves Gaming on for a week
/// without noticing, and offers a plain way back to nothing.
struct ActivityButton: View {
    @State private var activities = ActivityStore.shared

    var body: some View {
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
            if let current = activities.current {
                Label(current.displayName, systemImage: current.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "figure.walk.motion")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(activities.current.map { "Activity: \($0.displayName)" } ?? "Set activity")
    }
}
