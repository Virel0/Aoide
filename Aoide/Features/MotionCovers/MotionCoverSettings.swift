import MeleteKit
import SwiftUI

/// Settings → Motion Covers: this phone's switch, and, while the server makes
/// them, whether to see the ones it made from still covers (the server keeps
/// that choice, for every device).
struct MotionCoverSettings: View {
    @AppStorage(MotionCovers.enabledKey) private var isEnabled = true
    @State private var choice: MotionCoverChoice?
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Motion Covers", isOn: $isEnabled)
            if isEnabled, let choice, choice.on {
                Toggle("Ones Your Server Made", isOn: Binding(
                    get: { choice.showGenerated },
                    set: { shows in Task { await setShowsGenerated(shows) } }
                ))
            }
            if let problem {
                Text(problem).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Motion Covers")
        } footer: {
            Text("""
                Albums with a looping video play it, muted, over the cover on the album's \
                page and in the player. Off with Reduce Motion or Low Power Mode. Your \
                server can also make them from still covers when its admin turns that on.
                """)
        }
        .task {
            guard let client = AppSession.shared.client else { return }
            choice = try? await client.motionCoverChoice()
        }
    }

    private func setShowsGenerated(_ shows: Bool) async {
        guard let client = AppSession.shared.client else { return }
        problem = nil
        do {
            choice = try await client.setShowsGeneratedMotionCovers(shows)
            await MotionCovers.shared.removeAll()
        } catch {
            problem = (error as? MeleteError)?.errorDescription ?? error.localizedDescription
        }
    }
}
