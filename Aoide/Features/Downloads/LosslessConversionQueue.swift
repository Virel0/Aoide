import Foundation
import PlaybackKit
import os

/// Converts downloaded FLAC files to Apple Lossless, one at a time.
///
/// One at a time on purpose. A download finishing is one file, but a launch that
/// finds a hundred FLAC files from before conversion existed is a hundred, and a
/// hundred encoders at once would make the phone hot for nothing — they compete
/// for the same cores and finish no sooner in total. An actor doing synchronous
/// work is the simplest serial queue there is.
actor LosslessConversionQueue {
    static let shared = LosslessConversionQueue()

    private let log = Logger(subsystem: "com.example.aoide", category: "downloads")

    /// Writes `flac` as Apple Lossless at `target`, via a scratch name so a crash
    /// mid-write can never leave a half file wearing the real one's name.
    /// Returns false, having cleaned up, when the conversion did not happen.
    func convert(flac: URL, to target: URL) -> Bool {
        let scratch = target.appendingPathExtension("converting")
        do {
            try LosslessConverter.convertFLAC(at: flac, to: scratch)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: scratch, to: target)
            return true
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            log.error("Couldn't convert \(flac.lastPathComponent, privacy: .public) to Apple Lossless: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
