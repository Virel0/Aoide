# Contributing

Bug reports, fixes and features are welcome. For anything larger than a fix,
open an issue first, so the change can be agreed before the work. The app and
[Aoide for Linux](https://github.com/Virel0/aoide-linux) share their sync
contract and their names for things, so a change to one often has a twin in
the other.

## Build and run

You need Xcode 26 and an iPhone on iOS 26, or the iOS Simulator.

```sh
cp Config/Local.example.xcconfig Config/Local.xcconfig
open Aoide.xcodeproj
```

Fill in your own `DEVELOPMENT_TEAM` and `AOIDE_BUNDLE_ID` to run on a device;
the simulator needs neither. From the command line:

```sh
xcodebuild -project Aoide.xcodeproj -scheme Aoide \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Never commit `Config/Local.xcconfig`: it holds your team ID and bundle
identifier.

## Tests

The logic is in three local Swift packages, tested without a simulator:

```sh
cd Packages/CurationKit && swift test    # store, op log, sync, smart playlists
cd Packages/JellyfinKit && swift test    # API client, import matching
cd Packages/PlaybackKit && swift test    # queue, conversion, silence bounds
```

There is no CI on this repository yet, so run all three before you push, and
build the app once for the simulator.

## Making a change

- Keep a pull request to one change. Tests come with the code they cover.
- A change to what the app and the sidecar exchange starts in
  [docs/sync-design.md](docs/sync-design.md) or the matching brief in docs/.
- Interface text follows the app's existing words; errors say what happened
  and what to do next.
- Screenshots and test data use made-up artists, albums and accounts: never a
  real server address, library, token or name.

## Commit messages

Look at `git log` for the style. The subject is one plain sentence in the
imperative, sentence case, no prefix and no full stop:

```
Keep changes queued while the server is down
```

The body says why, what was measured or tested, and anything left undone.

## Licence

By contributing you agree that your work is released under the project's
licence, GPL-3.0-or-later.
