import SwiftUI

/// Settings → Motion Covers: this phone's switch.
struct MotionCoverSettings: View {
    @AppStorage(MotionCovers.enabledKey) private var isEnabled = true

    var body: some View {
        Section {
            Toggle("Motion Covers", isOn: $isEnabled)
        } header: {
            Text("Motion Covers")
        } footer: {
            Text("""
                Albums with a looping video in their folder play it, muted, over the cover \
                on the album's page and in the player. Off with Reduce Motion or Low Power Mode.
                """)
        }
    }
}
