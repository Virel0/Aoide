# Infinity: let the server choose what plays next

*Asked of the sidecar on 2026-09-11 from the client side. Asked after a listener
with Auto DJ on found the set choosing records whose names matched the one
playing — which turned out to be the Songs list, not Infinity — and then asked
the better question: why is Infinity a phone ranking a random sample at all?*

## Where we are

Infinity is what keeps the queue going. Both clients do the same thing:

1. Ask Jellyfin for an **Instant Mix** seeded by the record playing.
2. Drop anything flagged *not interested* and anything already queued.
3. Rank what is left by **taste** from the local play history, and take the
   best twenty.
4. With Auto DJ on, ask each candidate ahead of time the question the mix will
   ask — *can you follow this?* — and add that answer to the ranking, worth more
   than any single taste factor.

Step 4 was built this week and it works. Steps 1–3 are the problem, and no
amount of ranking fixes them:

**The pool is a random sample.** Jellyfin's Instant Mix for a song is, in the
server's own code, *songs sharing any of its genres, in random order, two
hundred of them*. No genre tag on the seed and it is two hundred random songs
from the whole library. The client then chooses the best of a hundred of those.
It never sees the record that would actually have been right.

**The ranking is blind to the music.** Taste knows genre, artist, finish rate
and what was heard lately. It knows nothing about tempo, key, energy, vocals,
or where the set has been for the last twenty minutes. Two records that would
mix perfectly are ranked no differently from two that clash — until Auto DJ
asks, and Auto DJ can only ask about records it has the grid and arrangement
for, which the phone has to fetch first for every candidate, then *wait two
seconds* hoping they arrive.

**There are two of it.** The phone and the desktop each rank from their own
history. They already disagree, and every improvement has to land twice.

## Why the sidecar

Everything the right answer needs is already there, and nowhere else:

| what | where it is |
| --- | --- |
| the **whole library**, not a sample | the server |
| beat grid, key, tempo, `bpmStability` | measured, stored, per track |
| arrangement: sections, energy, phrases, vocals | measured, stored, per track |
| loudness | measured, stored, per track |
| what this listener finished, skipped, liked, flagged | `play_events`, `likes`, `track_flags` — synced from **both** devices, merged |
| what is in the queue right now | `queue_state` — or simply sent with the request |

The client-integration doc says, deliberately, *"no model of taste, and no
opinion about what to play next."* This asks it to have both. Not a
recommender, not a model in the learned sense: arithmetic over what the server
already holds, where every position it produces can be explained in one
sentence — the rule the clients follow now, moved to where the data is.

## What is wanted

### 1. The endpoint

```
POST /aoide/next
```

```json
{
  "seed": "jellyfinId",
  "queue": ["jellyfinId", "…"],
  "recent": ["jellyfinId", "…"],
  "mode": "infinity",
  "limit": 20
}
```

- `seed` — the record playing. The one everything is asked to follow.
- `queue` — what is already queued *after* the seed, in order. Never returned
  again, and the last few are what the arc is read from (§3.5).
- `recent` — what this device heard lately, newest first, up to forty. The
  server has `play_events` too, but sync lags by minutes and a set is judged in
  seconds; the request is the truth about the last hour.
- `mode` — `infinity` or `autodj`. The difference is one factor (§3.4) and one
  exclusion.
- `limit` — how many to return, best first. Twenty is what the clients take now.

```json
{
  "candidates": [
    {
      "id": "jellyfinId",
      "score": 0.83,
      "factors": {
        "taste": 0.71,
        "freshness": 1.0,
        "similarity": 0.62,
        "mixability": 0.79,
        "arc": 0.9
      }
    }
  ],
  "profile": { "events": 184, "since": 1749600000000 }
}
```

`factors` is not decoration. It is how "why did it pick *this*?" gets answered
by numbers instead of by ear, and how a bad pick gets diagnosed in one message
rather than a screen recording. The clients will show it. `profile` says how
much history the taste term stood on; with too little (§3.1) the clients know
to say so.

A POST, because a queue can be long and ids are opaque. Same shape of error as
the rest: 503 when storage is down, 404 for an unknown seed.

### 2. The pool

Every audio track in the library the user can see, **minus**:

- anything flagged `notInterested` — never, in any mode
- anything in `queue` or `recent`
- the seed itself
- in `autodj` mode, nothing extra: an unmeasured record is not excluded, it
  simply earns no mixability (§3.4) and ranks by the rest. A set should not go
  quiet because half the library has not been analysed yet.

Then every remaining track is scored. The library is one person's; scoring
twenty thousand rows in memory is a few milliseconds and needs no index of
anything. If that ever stops being true, sample by genre *first* and score the
sample — but it is not true today and the point of this brief is to stop
sampling.

### 3. The score

Five factors, each in 0…1, summed with weights, two penalties subtracted, ties
broken on id so the same library and the same history give the same answer
twice. Every factor below that the clients already compute is stated with the
arithmetic they use, so the first version of the server matches the phone to
the last decimal and the parity tables (§5) can say so.

#### 3.1 Taste — weight **1.0** of the sum below

From `play_events` with `completed = 1`, the latest **200** within the last
**90 days**, for this user, from every device. (A skip is not a fact about
taste; a finish is. Jellyfin's own play counts are useless here because they
count a skip at four seconds as a play.)

- **genre** — count each genre of each finished play; divide by the largest
  count so the strongest genre is 1. A candidate scores the *best* of its
  genres, not the sum: a track tagged with six genres is not six times as
  relevant as one tagged with the right one. Genre names compared lowercased.
  Weight **0.45**.
- **artist** — the same, over album artist (or first artist when there is
  none). Weight **0.3**. Less than genre on purpose: a queue that keeps going
  should widen out from what is playing rather than stay on the same four
  artists all evening.
- **finish bias** — the candidate's own `completed / starts`, minus 0.5, times
  2, times **0.3**. Only when `starts ≥ 3`; below that it is noise and
  contributes 0. A track this listener never finishes is pulled down; one they
  always finish is pulled up.

`taste = genre·0.45 + artist·0.3 + finishBias`, which lands in about −0.3…1.05.
Clamp to 0…1 for the report; use the raw figure in the sum, as the clients do.

With **no finished plays at all** in the window, taste is 0 for everything and
`profile.events` says why — the clients then fall back to the station's own
order today, and will show "learning what you like" tomorrow.

#### 3.2 Freshness — two penalties, not a factor

- Heard lately (in `recent`, or in the last **40** distinct tracks this user
  started on any device, finished or not — a song skipped an hour ago is still
  a song you have just heard): **−1.4**. Wider than the whole of the rest of
  the scale. Deliberately absolute: a queue that keeps going has to keep going
  somewhere *new*, and the song that fits perfectly is exactly the song that
  would otherwise come round every twenty minutes.
- By an artist heard lately (the artists of those same 40, plus the artists of
  the last **3** in `queue`): **−0.4**. Smaller than the record's own penalty
  and larger than the artist bonus, so the same artist twice in a row loses to
  a different artist that fits nearly as well. The same artist twice in a row is
  the one repetition a room notices, and "most similar next" picks it every
  time unless something says otherwise.

Reported as `freshness`: 1.0 untouched, 0.5 same artist, 0.0 heard lately.

#### 3.3 Similarity to the seed — weight **0.4**

New. The factor taste cannot supply, from the measurements only the server has.
Four parts, mean of those that can be answered (a part with no data on either
side is left out of the mean, not scored 0.5):

- **genre** — 1 if any genre is shared with the seed, else 0.
- **tempo** — the ratio of the two BPMs after halving or doubling one to bring
  it within 0.7…1.4; then the clients' curve: 1 when the bend is ≤ 2%, falling
  linearly to 0 at 6%, 0 beyond. Tempo is the sidecar's `bpm`, only when
  `bpmStability` is what the clients already accept for a lock.
- **key** — Camelot: 1 when the same, or ±1 on the wheel, or the relative
  major/minor (same number, other letter); 0.5 when either is unknown; 0
  otherwise.
- **energy** — 1 − |seed's mean section energy − candidate's mean section
  energy|, with the mean weighted by section length.

#### 3.4 Mixability — weight **0.6**, `autodj` mode only

Exactly the planner's score for the pair *seed → candidate*: the five-factor
mix score the clients compute in `MixScore` (tempo 0.2, key 0.2, vocals 0.15,
energy 0.2, sections 0.25) at the best entry the planner would choose, after
every refusal rule the planner applies. A pair the planner refuses — both
singing across the overlap, tempo out of bend, either record unread — scores
**0.15**, the "it can still be crossfaded" figure, not 0. A candidate with no
grid or no arrangement earns nothing here at all (the term is absent, not 0.15,
so an unread record neither gains nor loses against a read one on this factor).

This is the third port of `DJPlanner` (Swift and TypeScript exist) and the one
that must not drift: the ranking's opinion of a pair and the client's plan for
it have to be the same number, or the set will book a mix the ranking did not
choose it for. §5 covers how that is held.

In `infinity` mode the term is absent and similarity (§3.3) carries the musical
side alone.

#### 3.5 Arc — weight **0.2**

New, and the one thing neither client can do, because only the server sees the
set as a whole. Read the energy of the last four records — the seed and the
three before it in `queue`, or in `recent` when `queue` is shorter — as the
mean section energy of each. Then a target for the next:

| the last four | the set wants | target energy |
| --- | --- | --- |
| rose three times in a row | a breather | seed − 0.25 |
| fell twice in a row | to come back | seed + 0.2 |
| otherwise | to hold | seed |

`arc = 1 − |candidate energy − target|`, clamped to 0…1. A record with no
arrangement scores 0.5 here. Small on purpose: the arc nudges, it does not
program. The rule is crude and is meant to be replaced by a better one once
there is a set to listen to; what matters now is that the *shape* of the set is
somewhere in the score, and that where it is can be pointed at.

#### The sum

```
score = taste
      + similarity · 0.4
      + mixability · 0.6          (autodj only, when measurable)
      + arc · 0.2
      − 1.4 if heard lately
      − 0.4 if by an artist heard lately
```

Best `limit` by `score`, then by `id`. The clients enqueue the result in that
order and ask again when the queue runs short, with the new seed and the new
queue. No state on the server between calls: everything the answer depends on
is in the request or in tables that already exist.

### 4. Determinism

The same request against the same tables returns the same list. No random
tie-break, no sampling, no "explore" term. Variety comes from the freshness
penalties, which is the right place for it: it is explainable. A list that
reshuffles itself between two calls is one nobody can debug.

### 5. Parity, and what the clients ship to hold it

The clients keep their local ranking as the fallback (§7) and it must agree
with the server's on every factor the two share, or a phone offline would build
a different set from the one it built online. So:

- **Taste, freshness, similarity, arc** — the clients will add a fixture file
  to both repos: a hand-written history (twelve finished plays, four skips, a
  flag), a library of twenty measured records, and the exact `score` and
  `factors` for each of them from a named seed, in both modes. The sidecar is
  asked to pass the same file. The clients' copies live beside the other parity
  suites in `Packages/PlaybackKit/Tests/PlaybackKitTests/*ParityTests.swift`
  (iOS) and `src/shared/aoide/*-parity.test.ts` (desktop), and this one will go
  in `CurationKit`'s tests on iOS.
- **Mixability** — the 40-pair `DJPlannerParityTests` table (bars, start ms,
  entry ms, rate, style, exact total) already exists in both client repos and
  is what the two existing planner ports were held to. The C# port is asked to
  pass all 40, plus the `BeatGridParityTests`, `ArrangementParityTests` rows
  it depends on. A pair scored differently from the phone is a bug in whichever
  side is wrong, and the table says which.

Mutation testing is how the clients decide a rule is real: every constant and
comparison above has a test that fails when it is changed. The sidecar's tests
are its own business, but a number here that can be changed without a test
failing is a number the next person will change.

## What this is not

- **Not a recommender.** No embeddings, no audio similarity, no learned model.
  The measurements are the sidecar's; the rule over them is this document's,
  and the rule is the kind that can be argued with line by line.
- **Not the set programmer.** Where a record is *left* — the 40–70% window, the
  cut on the phrase line, the echo-out — stays on the client: it needs the
  engine's clock. The sidecar has everything to compute the same exit point
  (`SetProgrammer` is pure arithmetic over grid + arrangement) and may return it
  later as a convenience, but nothing here depends on that.
- **Not a queue.** The server does not remember what it answered. The queue is
  the client's, and the client sends it back.
- **Not a change to sync.** No new entity. `queue_state` is not read; the
  request carries the queue.

## As built (sidecar 1.16.0.0), and what the client does with it

Shipped the same day, everything in the brief; the contract is in the sidecar's
`client-integration.md`. The third planner port passed all 40 pairs first run
(starts and entries within a nanosecond, totals to twelve decimals) and the
taste ranking all 16 rows. Two readings worth knowing, both the sidecar's and
both right:

- **Arc** reads the last four of `recent` (oldest first) + seed + `queue`, so
  with a queue the candidate follows the *end* of the queue, which is where it
  will actually play. With an empty queue it is the seed and the three before
  it, as written.
- **A track heard lately pays both penalties** (−1.8), because it is also by an
  artist heard lately. The phone's arithmetic does the same.
- **Similarity** with only one answerable part comes out 1.0 or 0.0 outright.
  A floor on how many parts must answer is a one-line change if the fixture
  wants one; sparse genre tags are where it would show.

### The fixture (§5), as written

`Packages/CurationKit/Tests/CurationKitTests/Fixtures/next-ranking-fixture.json`
— the same bytes as the desktop's `src/shared/aoide/next-ranking-fixture.json`.
Twenty records with tags, tempo, stability, key and sections; sixteen decided
listens (twelve finished, four skipped, one of them 91 days old) on a fixed
clock; one `notInterested` flag; and seven requests, each with `events` and
every candidate's `score` and `factors` to six decimals, in order. The
sidecar is asked to load the file and pass all seven. Two reference ports
pass it now — Swift (`NextRanking`, which generated it) and TypeScript
(`next-ranking.ts`) — and four of the rows are also worked by hand in
`NextRankingFixtureTests`, so the file is not only what the code said.
Seventeen mutations of the rule (each weight, each threshold, the window,
the depth, the fold, the tie-break) fail it.

The readings the fixture pins, where the prose left room:

- **Finish counts** are decided listens (completed or skipped), all time —
  the window is the taste profile's, not the finish rate's.
- **`bpmStability` exactly 0.5 holds**; below it the tempo is left out. Null
  holds.
- **Tempo is folded**: 60 against 120 is one groove counted two ways, as the
  planner has it. (The fixture's `t11`, an unread ambient record at 60 BPM
  sharing one tag with the seed, ranks *first* on genre + tempo + key, with
  energy unanswerable and arc 0.5. That is the rule as agreed and the first
  thing to listen for on a real library; a floor of three answered parts
  would not change it, and the fix if it grates is to fold only for
  mixability, not for similarity.)
- **A rise is four energies strictly rising; a fall is the last three
  strictly falling.** A record without an arrangement is dropped from the
  four before either is counted, so three rising values with an unread
  record among them are not a rise.
- **The artists of the last three queued** count as heard lately; the
  fourth-last does not.
- **`mixability` is `null` throughout** — no grids in the fixture — and is
  written, not omitted. The planner's forty pairs pin it.

One reading the sidecar changed to match the fixture, worth knowing: a
decided listen is one that was completed or skipped, whether or not it
carries `endedAt`. The phone's `finishCounts` SQL still says `endedAt IS NOT
NULL`; on real data a completed or skipped event always has one, so the two
cannot diverge, but the fixture and the SQL do not say quite the same thing.

On the phone, Infinity asks `/aoide/next` first and enqueues the answer in the
server's order; a 404 turns the Instant Mix path back on for the session. Each
row the server chose shows its figures in the queue — "Taste 71% · Fits 62% ·
Mixes 79% · Arc 90%" — so a pick that feels wrong can be argued with by number.

## Round two: choose by kin, then order by what mixes

*Asked 2026-09-11, after a listener heard Homewrecker followed by EDM. His
words: Infinity should choose primarily from genre, taste and freshness —
and then, once the list is chosen, order it so that neighbours are mixable.*

He is right on both counts, and the first version had them tangled: genre
against the seed was a quarter of one factor at 0.4, so a candidate the room
liked could out-score one of the seed's own kind by a mile; and mixability
sat in the choosing score at 0.6, so with Auto DJ on the set was made of
whatever *mixed*, and a good record that could only be crossfaded lost to a
mediocre one in the same key.

### The rule, as it is now

**Choosing** (both modes):

```
score = taste
      + kinship · 0.6
      + similarity · 0.4
      + arc · 0.2
      − 1.4 if heard lately
      − 0.4 if by an artist heard lately
```

- **kinship** — new, and the largest single term after taste: 1 when the
  candidate shares a genre with the seed, 0 when both are tagged and none is
  shared, 0.5 when either is untagged and nothing can be said. This is what
  "what plays next" mostly means: a pop record playing is not followed by a
  techno one however well the room likes techno.
- **similarity** — tempo, key, energy, as before; the genre part moves out to
  kinship. The mean of the parts that can be answered.
- **mixability is not in the choosing score at all**, in either mode.

**Ordering**, `autodj` mode only: the chosen `limit` records are put in the
order they should play — a chain from what the first of them will follow
(the last of `queue`, or the seed when nothing is queued): each next is the
record with the highest planner score for the pair *(last → candidate)*; a
pair refused or unread counts **0.15**, the crossfade figure; ties go to the
better-chosen record, then the id. The `score` reported is the choosing
score; the `mixability` reported is the pair's, from the record before it in
the order (`null` when unread). In `infinity` mode the order is the choosing
order and `mixability` is `null`.

`factors` gains `kinship`. The clients read it as optional, so a 1.16.x
server still parses.

### The fixture, round two

The same file, regenerated: every case's `expected` moves with kinship, and
a top-level **`mixability`** table (`"from>to": score`) stands in for the
planner's pair scores so the chain can be pinned without grids — a pair not
in the table is unread. An eighth case, `autodj … ordered as a chain`, is
the one that pins the ordering: chosen `t16 t20 t14 t11 t15` by score, played
`t16 t20 t14 t15 t11` because `t14→t15` is 0.9 and `t14→t11` 0.6, with `t11`
last though its choosing score is higher — a candidate chosen for its kind
and its taste, placed where it mixes. Both client ports pass all eight; ten
mutations of the round-two rule (the weight, the untagged case, where the
chain starts, the crossfade figure, the tie, the mode gate) fail it.

## What the clients will do with it

- Infinity asks `/aoide/next` instead of Jellyfin's Instant Mix, and enqueues
  the answer in order — no local ranking, no prefetch-and-sleep. With Auto DJ
  on, the grids and arrangements for the twenty returned are fetched as they
  are enqueued, which is twenty requests instead of two hundred.
- The queue shows `factors` on each Infinity row, so "why this?" has an answer
  on screen.
- One ranker, one answer: the phone and the desktop build the same set from
  the same seed.

## What the clients will do if it never arrives

Exactly what they do today: Instant Mix, filtered, ranked locally by taste and
— with Auto DJ on — by mixability of whatever happens to be in the sample.
The switch is the endpoint's presence: a 404 from `/aoide/next` and the client
falls back for the session. Ship in either order.
