# Beat grid: what Auto DJ needs

*Asked of the sidecar on 2026-09-10, from the client side. The third measurement
in the same family as [sound bounds](sound-bounds.md) and
[audio analysis](audio-analysis.md), and the same decode again — but the answer
this one wants is a different kind of thing, so it is worth being exact about
before anyone writes code.*

## The name, and why the bar is this high

Aoide has **Crossfade** (one song faded into the next, length chosen per pair)
and **Infinity** (the queue keeps going). Neither is called a DJ, and the word is
being kept back deliberately for the thing people actually mean by it:
transitions that are *mixed* — beat aligned, bar aligned, the bass swapping over
on a downbeat, both tracks running at one tempo for the length of the blend.

That is what **Auto DJ** will be, and it cannot be built on a BPM. The current
measurement is excellent at what it is for — within 0.2 BPM, and
`bpmStability` says when even that describes the track — but as
`audio-analysis.md` already puts it: *half a per cent still drifts most of a
second across a three-minute track*. A blend that starts beat-locked and is a
sixteenth-note out by bar eight sounds worse than no beat-matching at all,
because the ear forgives two unrelated grooves and does not forgive one groove
that is nearly right.

So the ask is not a better number. It is the **positions**.

## What is wanted

### 1. The grid

A fit, not a list — a list of four hundred beat timestamps is the same
information at ten times the size, and a fit says something a list does not:
how well the track actually holds a grid.

```
anchorMs      the position of one beat, as exactly as the fit can place it
bpm           the fitted tempo (may differ slightly from the reported bpm)
residualMs    RMS distance between the fitted beats and the detected onsets
beats         how many beats the fit spans
```

`beat(n) = anchorMs + n × 60000 / bpm`

**`residualMs` is the field that decides whether Auto DJ runs at all.** A blend
of sixteen bars at 128 BPM is thirty seconds; to stay inside a twentieth of a
beat across it, the grid has to be good to about 20 ms end to end. A track whose
onsets sit 60 ms off its own fitted grid is not a track anything can be locked
to, and saying so is far more useful than a grid that looks authoritative.

A track that genuinely changes tempo should come back as **segments**, each with
its own anchor, bpm and residual, rather than one fit smeared across the change:

```json
"segments": [
  { "startMs": 0,      "endMs": 96000,  "anchorMs": 431.2,   "bpm": 128.02, "residualMs": 9.4,  "beats": 205 },
  { "startMs": 96000,  "endMs": 214000, "anchorMs": 96210.5, "bpm": 140.01, "residualMs": 11.8, "beats": 275 }
]
```

Most tracks will be one segment. A client mixes only within a segment that is
long enough to hold the blend, which is the honest way to handle a track that
speeds up.

### 2. The downbeat

Beats are not enough. Aligning beat to beat but landing bar three of one track
on bar two of the other is the classic way to make a mix that is technically in
time and audibly wrong.

```
beatsPerBar     4 for nearly everything; 3 for waltzes; null when unsure
downbeatIndex   which beat of the fit is a bar's first — 0…beatsPerBar-1
```

If the meter cannot be established, `null` for both is the right answer, and the
clients will not offer a bar-aligned transition for that track.

### 3. The mix points

Where a transition may begin and end, in the track's own timeline:

```
mixInMs     where a blend may bring this track in — the first downbeat of the
            first bar that is actually playing, past any intro that is only
            atmosphere
mixOutMs    where a blend may take this track out — the downbeat of the last
            bar before the ending stops being part of the groove
```

Both should land on downbeats of the fit. The clients can compute something
crude from sound bounds and the grid, but the server has the decoded audio and
the energy envelope already, and one implementation of this beats two.

### 4. The key, if it is cheap

```
key         "8A" (Camelot) or "Am", null if not measured
keyConfidence
```

Only worth doing if it falls out of the same pass. Harmonic mixing is a
nice-to-have; the clients would use it to *prefer* a pair, never to refuse one.

## Endpoint

Same shape as its two siblings, so the client code is the same code:

```
GET /aoide/beat-grid?ids=<jellyfinId>,<jellyfinId>,…            (≤ 200 ids)
Authorization: MediaBrowser Token="…"

200 {
  "grids": {
    "<jellyfinId>": {
      "segments": [
        { "startMs": 0, "endMs": 214000, "anchorMs": 431.2, "bpm": 128.02, "residualMs": 9.4, "beats": 456 }
      ],
      "beatsPerBar": 4,
      "downbeatIndex": 0,
      "mixInMs": 15431,
      "mixOutMs": 187431,
      "key": "8A",
      "keyConfidence": 0.71
    },
    "<jellyfinId>": null      // measured; no grid worth having
  },
  "pending": ["<jellyfinId>"]
}
```

Every field independently nullable, lazy measurement with `pending`, cached
against the file's modification time, unknown ids omitted — all exactly as the
other two endpoints already behave.

## What the clients will do with it

Refuse, mostly, and that is the point. A transition is only offered when:

- both tracks have a grid whose `residualMs` is small enough for the blend's
  length,
- both have a meter and a downbeat,
- the tempi are within the range one can be stretched to reach without sounding
  stretched (about ±6%, after folding into one octave), and
- the blend fits between one track's `mixOutMs` and the other's `mixInMs`.

Everything else falls back to [Crossfade](crossfade.md), which is already built
and already good. **Auto DJ is a thing that happens sometimes, not a mode.** A
player that beat-matches when it can and crossfades when it cannot is a player
people trust; one that tries every time is one they turn off.

## What this does not need

Not stems, not per-instrument separation, not a neural model. If the grid and the
downbeat are right, the difference between a crossfade and a mix is the client's
job: aligning the two clocks, running one deck at the other's tempo, and taking
the bass out of the outgoing track on a downbeat.
