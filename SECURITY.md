# Security

## Reporting a vulnerability

Please report security problems privately, through GitHub's private
vulnerability reporting: open the repository's **Security** tab and choose
**Report a vulnerability**, or go straight to
<https://github.com/Virel0/aoide/security/advisories/new>. Don't open a public
issue for them.

Say what you found, the commit you built, the iOS version and device, and the
steps that show it. Replies come in the advisory thread; the aim is to fix the
problem before the advisory is published.

Problems in the Aoide sidecar plugin belong in
[Virel0/aoide-sidecar](https://github.com/Virel0/aoide-sidecar), and problems
in the Linux app in [Virel0/aoide-linux](https://github.com/Virel0/aoide-linux).

## Supported versions

There are no tagged releases yet. Fixes go to `main`.

## What the app stores, and where

| What | Where |
|---|---|
| The Jellyfin access token | The keychain, available after the first unlock so CarPlay can start playback on a locked phone; not in `UserDefaults`, which backups can read |
| Playlists, likes, taste flags, the play history, the sync log | A SQLite database in the app's Application Support folder |
| Downloads, playlist covers, recent contexts | The app's container on the phone |
| Preferences (appearance, Crossfade, Trim Silence and the like) | `UserDefaults` |

Signing out removes the token. Deleting the app removes everything on the
phone. Data synced to your server lives there, under your Jellyfin account.

## What the app sends, and to whom

The README's [Privacy](README.md#privacy) section and
[docs/privacy-policy.md](docs/privacy-policy.md) list it: your Jellyfin server
and its sidecar; Spotify's public playlist page only when you import one;
Apple for Siri requests if you allow Siri, and for the one-time download of a
translation language. Mixes, sentence search and lyric translation run on the
phone. Settings → Diagnostics writes the app's own log from the last half hour
to a file you share yourself; nothing is sent otherwise.

## Secrets in the repository

Nothing personal is committed: the team ID, the bundle identifier and the
default server address live in `Config/Local.xcconfig`, which is gitignored.
The committed placeholder is `com.example.aoide`.
