# Arrangement: what a mix still cannot see

*Asked of the sidecar on 2026-09-10 and **shipped in 1.15.0.0** the next day; the built contract is in the sidecar's own `client-integration.md`. Asked after a listener said a beat-matched,
key-aware, bass-swapping transition still did not sound like a DJ had made it.
He was right, and the reason is not in the grid.*

## Where we are

The [beat grid](beat-grid.md) gave us the two things a transition is built on,
and they work: two records land on the same beat and stay there, and the low end
belongs to one of them at a time. Measured on the decks, two records a beat
apart come out within two milliseconds of each other across a fifteen-second
mix, and the level holds within a decibel of one record playing.

That is the *physics* of a mix. What is missing is everything about the
**music**.

## The four things a transition has to get right

A DJ's own account of it, and where we stand:

| | | |
| --- | --- | --- |
| **Tempo and phase** | Same tempo, kicks on the same beat | **Done.** Bend of at most 6%, pitch preserved, sample-accurate start on a downbeat, both decks on one clock |
| **Phrase** | Mix on 8/16/32-bar boundaries: intro into outro, build into build | **Half.** The mix is a whole number of bars and both ends land on downbeats — but nothing here knows where a *phrase* starts, let alone an intro or a drop |
| **Key** | Same, adjacent, or relative on the Camelot wheel | **Half.** Keys are read; a clash shortens the mix. Nothing filters or ducks to hide one |
| **Energy** | Similar density and weight; gain-matched first | **Gain only.** Both records are levelled to −18 LUFS. Nothing knows a breakdown from a peak |

The gap that matters most is the second one, and it has a name: *dropping a new
chorus on someone else's chorus is the most common amateur mistake.* Nothing in
this system can currently avoid making it, because nothing knows which part of
either record is playing.

## What is wanted

Per track, from the decode that already happens:

### 1. Sections

```
sections: [
  { "startMs": 0,      "endMs": 30040,  "kind": "intro",      "energy": 0.21 },
  { "startMs": 30040,  "endMs": 60080,  "kind": "build",      "energy": 0.55 },
  { "startMs": 60080,  "endMs": 120160, "kind": "drop",       "energy": 0.94 },
  { "startMs": 120160, "endMs": 150200, "kind": "breakdown",  "energy": 0.38 },
  …
]
```

Boundaries on downbeats of the existing grid, and ideally on phrase boundaries.
`kind` from a small closed set — `intro`, `build`, `drop`, `breakdown`,
`outro`, `verse`, `chorus`, `unknown` — with `unknown` an honest and expected
answer. `energy` normalised within the track, so a quiet record's drop still
reads as its loudest part.

**What the clients would do with it:** bring a record in during something thin
and take one out during something that is ending. Never start a drop under
another drop. Prefer a mix whose two sides agree in energy, which is the fourth
requirement above and is unreachable without this.

### 2. The phrase grid

```
phraseBars: 8            // or 16, or null when the structure will not commit
phraseAnchorMs: 19994.5  // the downbeat that begins a phrase
```

Bars are known already; phrases are not, and they are what a mix is counted in.

### 3. Vocals

```
vocals: [ { "startMs": 45000, "endMs": 88000 }, … ]
```

Two lead vocals over each other is the other thing on every DJ's list of what
not to do, and it is not something a client can hear. Rough is fine: a client
would use it to refuse an overlap where both records are singing, and to prefer
an outgoing instrumental passage.

## What this is not

Not stems, not a neural model of taste, not a recommendation of what to play
next. Section boundaries and a vocal flag are measurements of a file, in the
same family as loudness, silence bounds and the beat grid, and they come from
the same decode.

## What the clients will do if it never arrives

What they do now: refuse more often. Without knowing structure, a long mix is a
gamble on the two records being in compatible parts of themselves, and the safe
response to a gamble is a shorter overlap. Every improvement here is an
improvement in how *often* a mix can be attempted, not in whether one is
possible at all.


## As built (sidecar 1.15.0.0), and what the client does with it

All three parts. Two things the rig caught on the way, both of which changed
tempi the clients already held: a short loud passage had been deciding whole
tracks' tempi (one file read 73 BPM with its sung bridge and 128 without), and a
beat-free breakdown had been inventing tempo changes. The server dropped every
tempo and grid it had measured so the levelled estimator could take them again;
iOS drops its own caches of both for the same reason.

Decisions relayed and honoured:

- `verse` and `chorus` are never returned; `unknown` is common and real.
- `vocals` has three states. **`null` is treated as singing throughout.**
- A build must sit between something quieter and something louder, or every
  breakdown before a drop would have been one.

The planner (`DJTransition.swift`) now does three things it could not:

1. **Starts a mix on a phrase line**, not merely a bar line, on both records —
   the outgoing start goes back to the phrase it sits in, and the incoming entry
   does the same from its mix-in point.
2. **Refuses a mix where both records may be singing** during the overlap. An
   unknown counts as singing: a false positive costs a mix, a false negative is
   two voices over each other.
3. **Gives a drop-onto-a-drop eight bars rather than sixteen.** Nothing here can
   yet find a better place to come in; it can decline to sit there for long.

Energy is not used yet. It is the ingredient for choosing *where* to come in —
a build rather than a drop — which is the next thing.


## Scoring, and the crossover

Two more from the sidecar's reading of how others have done this, both taken.

**A weighted score sets the length.** Refusing on one criterion at a time meant
a key clash was eight bars and a tempo gap was no, and nothing in between could
be said. `MixScore` grades five things — tempo (free to two per cent, gone at
six), key, singing, energy at the exit and entry, and what kind of section each
is — and the total earns thirty-two, sixteen or eight bars, or a crossfade. A
pair with nothing *known* against it gets sixteen; half a minute together has to
be earned by knowing the records suit each other. Two hard rules stay outside
the score, because a score can be outvoted and some mistakes should not be: two
records singing is refused, and a drop onto a drop is capped at eight.

The score also chooses **where the incoming record comes in**: its mix-in point,
or the start of any build, intro or breakdown it has, whichever scores best —
coming in on the build is what a DJ does, and the mix-in point is only where the
groove starts.

**The bass swap is a high-pass now, not a shelf.** A shelf turns the low end
down; a kick's harmonics and a bass line's upper notes still come through it,
and two of those under each other is exactly the mud the swap exists to stop. A
second-order high-pass takes the low end out, and its corner is swept across the
swap on a log scale from 20 Hz to 220 Hz — halfway is 66 Hz, not 120, because
that is how frequency is heard. Rendered and measured: the level through a mix
still holds within a decibel, and 60 Hz is 22 dB down on the record that has
given its bass up.

**Not taken:** ramping the bend in over the first bars. The incoming record is
bent before it is audible and eased back over eight seconds after the mix, so
there is no moment at which a listener could hear the bend arrive.


## Homewrecker into Birds of a Feather

Two pop records, ~100 into ~105, 3B into 10B, a voice on each. A listener
reported the result as "mashing the beats and vocals together", and a DJ's
account of how the pair *should* be handled — a short, EQ-managed hand-off,
never a long harmonic blend — found exactly where this was wrong.

**It had mixed them on tempo and key alone.** The arrangements had not been
fetched (the server had just dropped its rows to re-measure), and without them
the score treated "nothing known" as neutral: eight bars, two singers, two keys.
So: **a record that has not been read is not mixed.** Matching tempo is not a
substitute for knowing the arrangement, and a record the server has not got to
yet crossfades, which is fine.

**A known key clash is capped at eight bars**, whatever the score says.

**Something to hide gets the filter fade.** When the keys are known to clash or
either record is singing across the overlap, the outgoing record's high-pass
corner sweeps up to 1.5 kHz across the first half of the mix — bass, chords and
the body of a voice go; hats, snare and air stay — so by the time the incoming
record has its bass, the old one is rhythm. Its melody and the new one's are
never on top of each other, which is the whole point. Rendered and measured:
the pair thins by design and never drops more than six decibels below one record
alone. Pairs with nothing to hide keep the blend; a filter on every hand-over is
how a robot announces itself.

**The incoming record comes up over half the mix**, not within a bar. A DJ
raises the new record's drums and top under the old one over eight to sixteen
bars; the bass still arrives at the swap, so this only governs how the hats and
the air get there.
