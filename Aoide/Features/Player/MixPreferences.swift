import Foundation
import PlaybackKit

/// Crossfade: whether one song is faded into the next.
///
/// Off by default. It changes how every record on the device sounds, and a
/// player that starts doing that uninvited is a player that broke.
enum CrossfadePreference {
    static let key = "aoide.crossfade"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Album lock: never mix across two consecutive tracks of one album.
///
/// On by default, and it is what makes crossfading safe to leave on — a record
/// that was sequenced to run continuously still does.
enum AlbumLockPreference {
    static let key = "aoide.albumLock"
    static var isOn: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
