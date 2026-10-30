# Discover: the records you own and have not heard

> **Since 2026-10-30** Aoide runs on [Melete](https://github.com/Virel0/Melete),
> which serves the sidecar's `/aoide/*` routes at the same paths, signed in with
> Melete's tokens. Where this says Jellyfin ids, read Melete track ids. The
> brief is kept as written.

*Asked of the sidecar on 2026-10-23 from the client side. Discover Weekly,
for a personal library: a set of songs this listener owns but has barely or
never played, chosen by their taste, the same all week.*

## Why the sidecar

The phone could ask Jellyfin for unplayed songs and rank them, but it would
only see Jellyfin's own play counts — which count a skip at four seconds as a
play — and only this device's history. The sidecar already has the whole
library, the finished and skipped plays from every device, the taste flags,
and the ranking Infinity uses (`/aoide/next`, docs/infinity.md). Discover is
that ranking pointed at a different pool.

## What is wanted

```
GET /aoide/discover?limit=30
```

```json
{
  "week": "2026-W43",
  "candidates": [
    { "id": "…", "score": 0.91,
      "factors": { "taste": 0.8, "kinship": null, "freshness": 1.0, "similarity": null, "mixability": null, "arc": null } }
  ],
  "profile": { "events": 184, "since": 1749600000000 }
}
```

### The pool

Every audio track this user can see, **minus**:

- anything flagged `notInterested`;
- anything with **a finished play** (`completed`) in `play_events`, from any
  device, ever — the point is records not yet heard through;
- anything **started three or more times** without a finish — skipped
  repeatedly is an answer, not an unheard record.

Jellyfin's own `PlayCount` is not used: it counts skips.

### The score

Taste only, from `/aoide/next` §3.1 exactly — genre 0.45, artist 0.3 (the
finish bias is always 0 here: nothing in the pool has three decided listens).
No seed, so no kinship, similarity, mixability or arc: those factors are
`null`. Freshness is moot (nothing in the pool has been heard) and reported
as 1.

Two adjustments, so the list is a discovery and not a wall of one artist:

- **At most two records per artist**, and at most three per album.
- **Ties broken by a seeded shuffle**, not by id: the seed is the ISO week
  and the user id, so the list is the same all week, different next week,
  and the same on every device. Within a week, determinism holds — the same
  request returns the same list.

With **no finished plays at all** (`profile.events == 0`), taste is 0 for
everything and the list is the seeded shuffle of the pool, still capped per
artist and album: a new listener gets a varied sample of their library.

### Errors

As the rest: 503 when storage is down, 400 for a bad `limit` (1–100), and a
404 from the endpoint itself means an older sidecar.

### Parity

The taste arithmetic is already held by the 8-case `/aoide/next` fixture.
For this endpoint a small fixture of its own would pin the pool rules (the
finished, the thrice-skipped, the flagged), the per-artist and per-album caps,
and the week seed: same week → same list, next week → different. The clients
will add it beside `next-ranking-fixture.json` if the sidecar writes it
first.

## What the clients will do with it

- A **Discover** tile on Home, refreshed when the week changes, opening a
  playlist-like screen of the thirty songs with a Play and Shuffle button.
- The queue rows show the factors, as Infinity's do.
- Against an older sidecar (404) the tile is not shown.
