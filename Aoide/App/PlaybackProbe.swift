#if DEBUG
import AVFoundation
import Foundation
import JellyfinKit
import PlaybackKit

/// Plays a locally generated tone through the real engine and the real reporters.
///
/// Reached with the launch argument `-AoidePlaybackProbe`. It exists because the
/// playback path can only otherwise be exercised by signing in to a server, which
/// puts the one code path most likely to crash — start, report, record, advance —
/// out of reach of a simulator. The audio is synthesised rather than bundled so the
/// probe costs nothing in the shipped app.
enum PlaybackProbe {
    @MainActor
    static func run() {
        guard let url = writeSilence() else { return }

        // The real bridge, so the Jellyfin reporter and the curation recorder are both
        // attached exactly as they are in a signed-in session. The client cannot resolve,
        // which is correct: reporting to the server is meant to fail here, and the point
        // is what happens locally.
        if let server = try? JellyfinClient.normalizeServerURL("probe.invalid") {
            JellyfinPlaybackBridge.connect(
                client: JellyfinClient(serverURL: server, device: AppSession.deviceProfile)
            )
        }

        let track = Track(
            id: "probe-track",
            title: "Probe Tone",
            artist: "Aoide",
            album: "Diagnostics",
            duration: .seconds(3),
            streamURL: url,
            artworkURL: nil,
            trackNumber: 1
        )
        PlaybackEngine.shared.play([track])
    }

    /// Three seconds of silence as a 16-bit mono WAV, which AVFoundation opens without
    /// a codec.
    private static func writeSilence() -> URL? {
        let sampleRate = 44_100
        let frames = sampleRate * 3
        let dataBytes = frames * 2

        var wav = Data()
        func append(_ string: String) { wav.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF"); append32(36 + dataBytes); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate * 2); append16(2); append16(16)
        append("data"); append32(dataBytes)
        wav.append(Data(count: dataBytes))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.wav")
        do {
            try wav.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
#endif

#if DEBUG
import SwiftUI

/// The probe's screen: start playback, then show what the engine reports.
struct PlaybackProbeView: View {
    @State private var engine = PlaybackEngine.shared

    var body: some View {
        VStack(spacing: 16) {
            Text("Playback Probe").font(.headline)
            Text(engine.currentTrack?.title ?? "nothing playing")
            Text("state: \(String(describing: engine.state))")
            Text("elapsed: \(engine.elapsed.seconds, specifier: "%.1f")s")
            Button("Play") { PlaybackProbe.run() }
                .buttonStyle(.borderedProminent)
        }
        .monospaced()
        .task { PlaybackProbe.run() }
        .appBackground()
    }
}
#endif
