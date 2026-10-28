# Contributing

Bug reports, fixes and features are welcome. For anything larger than a fix,
open an issue first, so the change can be agreed before the work. The app and
[Aoide for Linux](https://github.com/Virel0/Aoide-Linux) share their sync
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

CI runs all three, builds the app for the simulator
(`.github/workflows/ci.yml`) and runs SwiftLint (`lint.yml`) on every pull
request; run them before you push anyway, it's faster.

## Lint

```sh
swiftlint lint                            # from the repository root
```

`.swiftlint.yml` holds the limits: files under 500 lines (1,000 at most),
functions under 50 (100 at most), types under 300 (600 at most), and no
force-unwraps or `try!` outside tests. Errors fail CI; warnings are worth
fixing when you touch the code anyway.

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
