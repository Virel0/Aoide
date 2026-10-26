# Changelog

Notable changes to Aoide for iPhone. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

The app has no tagged releases yet and isn't on the App Store; it is built
from source with Xcode. Until a first release is tagged, everything is under
Unreleased, and `git log` has the full history.

## [Unreleased]

### Added
- Discover on Home: the sidecar's 30 songs of the week, with Play and Shuffle.
- Lyrics translated on the phone with Apple's Translation framework, offered
  when they aren't in the listener's language.
- Changes stay queued while the server is down and go out when it is back.
- Taste flags are erased with the account they belong to.
- README, security policy, contributing guide, issue and pull request
  templates.

### Changed
- The bundle identifier is set only in `Config/Local.xcconfig`; a clean
  checkout builds as `com.example.aoide`.

### Removed
- Auto DJ and the stems brief are shelved: switched off and hidden, with the
  code and tests kept. [docs/arrangement.md](docs/arrangement.md) says why and
  what would bring them back.

### In the app so far
Home, the library, playlists with folders and smart playlists, mixes and
sentence search with Apple Intelligence, downloads with FLAC converted to Apple
Lossless, Trim Silence, Crossfade, Infinity, Replay, taste flags, activity
tags, Spotify playlist import, sync with the Aoide sidecar, queue handoff,
synced lyrics, CarPlay, Siri, SharePlay and AirPlay. The README lists them in
full.
