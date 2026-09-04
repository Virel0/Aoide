# Taste flags: "not interested" and "don't count this"

*Proposed 2026-09-04 by the app chat. Needs the sidecar's agreement before either client ships it.*

## Why

Every smart playlist, mix and station Aoide offers is computed from the play
history the clients keep. That history is only as good as its worst week: one
holiday of a child's playlist, or a sleep playlist that runs all night, skews
"Heavy Rotation", "Rediscover Mix" and every rule that reads `play_count` or
`last_played`, until it can be excluded. The brief we are following puts it
plainly: recommendations must be correctable.

Two flags, per track, synced like a like:

| flag | meaning | effect |
|---|---|---|
| `notInterested` | never offer this to me | excluded from mixes, stations, smart-playlist *results* and shuffle weighting; still playable and still in ordinary playlists |
| `dontCount` | a play of this is not a fact about my taste | new play events for it are not recorded at all; existing history is untouched |

## Wire form

A new entity, **`track_flags`**, not fields on `likes`: a like and a flag set
from two devices at once must both survive, and `likes` merges whole-row. This
one merges **per field** with `fieldUpdatedAt`, exactly like `playlists`.

```json
{
  "id": "…",                       // one row per track per user; uuid minted by the first writer
  "jellyfinId": "…",
  "contentKey": "…",               // so a relink after a rescan finds it, like everything else
  "notInterested": false,
  "dontCount": false,
  "updatedAt": 1757000000000,
  "originDevice": "…",
  "fieldUpdatedAt": { "notInterested": 1757000000000, "dontCount": 1756000000000 },
  "deleted": false
}
```

Ops travel through `POST /aoide/sync/push` / `GET /aoide/sync/pull` as today,
with `entity: "track_flags"`. Deduplication is by `(user, jellyfinId)` on
`applyRemote`, the same way `likes` dedupe on their unique index.

## Questions for the sidecar

1. Does the sidecar pass an op with an entity name it has not seen through the
   log untouched, or does it reject it? If it rejects, `track_flags` needs
   adding server-side before the clients can push one.
2. Export: nothing. Jellyfin has no concept of these; they never reach it.
3. Retention: same as `likes` (kept).

## Client work, once agreed

- CurationKit / curation-store: table `track_flags`, `SyncEntity.trackFlags`,
  per-field merge, `record()` path, and dedupe on apply.
- Recording: `beginPlay` returns early for a `dontCount` track.
- Evaluation: `SmartPlaylist.evaluate`, `Mix.narrow`, instant-mix/station seeds
  and `playWeights` all drop `notInterested`.
- UI: two toggles in every track context menu on both apps, and a "Hidden from
  mixes" list under Settings so a flag can be found and undone.
