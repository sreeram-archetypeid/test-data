# What the questionnaire tells us that the data cannot

Source: `ARENA_Fatal Fury Concept Test_Programming 061926.docx` — the canonical
QRE, 4 sections, 26 base-all questions plus 17 with conditional bases.

This document exists because reading it changed four conclusions and produced
one finding larger than anything found in the data alone.

---

## F11 — the synthetic panel ignored the questionnaire's routing

**This is the most consequential finding in the project.**

The QRE gates 17 questions behind conditional bases. Every persona answered
every question anyway.

| Question | QRE base | Should be | Actually answered |
|---|---|---:|---:|
| `PARENT2` | `P1 "YES" @PARENT1` | 107 | **398** |
| `POLORIENT` | `RESPONDENTS 18+` | 338 | **398** |
| `LIKE` | `P1-P2 @ POSTINT` | 355 | **398** |
| `DISLIKE` | `P2-P4 @ POSTINT` | 372 | **398** |
| `URG2` | `P2-P4 AT URG1` | 347 | **397** |
| `ELEMENT2` | `P2-P4 AT URG1` | 347 | **398** |

The clinching evidence: **all 398 personas answered both `LIKE` and `DISLIKE`.**
Those two questions are gated on opposite ends of purchase intent — `LIKE` on
`POSTINT` punches 1–2, `DISLIKE` on punches 2–4. They overlap only at punch 2.
A respondent answering both is valid only inside that narrow overlap. All 398
did it.

Similarly, 60 personas aged 13–17 answered `POLORIENT`, a question the QRE
restricts to adults. And roughly 51 personas who said they would see the film
opening weekend went on to answer `URG2` — *what would make you see it sooner*.

### Why this matters

1. **Distributions on gated questions are distorted.** `URG2`'s answers include
   people for whom the question is meaningless. That is not bad data; it is
   answers to a question that should never have been asked.
2. **Human-vs-synthetic calibration (Phase 5) compares different bases.** The
   W-Tabs (N=800 humans) ran through a real survey engine, so their `LIKE` base
   is genuinely restricted. Ours is not. Comparing them without correction
   compares different populations.
3. **This explains the "convenient" completeness we noticed early.** Every
   question slot is filled in every row — 40,178 is the exact product of rows ×
   questions. A routed survey produces gaps. The *absence* of gaps was the
   diagnostic signal, and we read it as tidiness.

### The fix

The QRE gives the rules, so this is recoverable in SQL. Add
`is_in_qre_base BOOL` to `fct_response`, computed from the gating question's
answer for each of the 17 conditional questions. Then every banner can state
which base it used:

- `WHERE is_in_qre_base` — matches how the human study would have run
- unfiltered — every answer the synthetic panel produced

Both are defensible. Silently mixing them is not.

---

## F12 — the panel also violated the qualifying screener

The QRE's `ACTIVITIES` block carries an explicit screen-out rule:

> `[MUST SELECT P2-4 ACROSS FOR P1 DOWN (IE SEE MOVIES IN THEATER AT LEAST
> EVERY SIX MONTHS BUT NOT DAILY) AND MUST ALSO SELECT P1-3 FOR P2 DOWN (IE
> PLAY VIDEO GAMES AT LEAST EVERY MONTH) OR MARK FOR EXCLUSION]`

So a qualifying respondent must answer the theatre item in punches 2–4 and the
video-games item in punches 1–3. Our data contains punches 5 and 6 on the
theatre item and punch 4 on video games — all of which are screen-outs.

Same root cause as F11: the persona generator answered the instrument without
enforcing its logic.

### The silver lining — this explains F8

We found eight questions whose observed maximum code was below the scale they
were offered, and corrected them using the battery maximum. The screener
explains *why* those tails are empty:

| Qualifier | Consequence |
|---|---|
| "Action genre fans and Anime non-rejector" | `GFAN1` punch 4 *"I never see these"* is a screen-out |
| "Aware of 1+ fighting videogames" | `VGFRAN1` punch 4 *"never heard of"* is a screen-out |
| "Plays video games at least monthly" | `ACTIVITIES` video-games tail is a screen-out |

The offered scale is genuinely longer than the qualifying population can
express. So the F8 correction was right, and `BOT% = 0` on those items is a
true and meaningful result — it says *nobody in the qualifying audience never
watches Action films*, which is true by design.

---

## F9 resolved — `ELEMENT1` is categorical, definitively

The QRE:

```
ELEMENT1   Please select how each of the following elements affect your
           interest in seeing this film in a theater.
[SINGLE SELECT] [ROTATE P1 & P2]
   Increases my interest
   Decreases my interest
   Does not change my interest [ANCHOR]
```

`[ROTATE P1 & P2]` is decisive. Punches 1 and 2 are **rotated** — their display
order is randomised — because they are opposing categories, not adjacent points
on a scale. Punch 3 is `[ANCHOR]`ed last because it is the neutral option.

You cannot rotate the ends of an ordinal scale. This is a three-way
categorical.

**Therefore:** `MEAN`, `BOT%` and `B2B%` are invalid on all 15 `ELEMENT1`
items. The banner plan's `MEAN = 1.2769` is not a quantity. Correct reporting
is three percentages: % increases, % decreases, % no change.

---

## F10 resolved — the theatre item's base

The `ACTIVITIES` scale is one 6-point frequency scale shared by all six items
(`Every day / Every week / Every month / Every 2-6 months / Once a year or less
/ Never`). The battery fix was right.

But the theatre item's screener excludes *Never*, which is why the banner plan
annotates it `(1=Every day … 5=Once a year or less; Never excluded from base)`
and reports `T3B` / `B2B (P4-P5)` / `MEAN (1-5, excl. Never)`.

**Therefore:** for the theatre item only, exclude punch 6 from the base and
report T3B (punches 1–3). Every other `ACTIVITIES` item keeps the full 6-point
base.

---

## The 800 / 998 / 398 reconciliation

Three sample sizes across three documents, and they are consistent:

| Number | Source | What it is |
|---|---|---|
| **800** | QRE `SAMPLE: n=800 (U.S.)` | the **human** study — this is the W-Tabs universe |
| **998** | banner plan, "18 sample frames" | the **synthetic** run, all modalities |
| **398** | our READ export | the READ subset of the synthetic run |

So the QRE is the shared instrument; the human study fielded 800, the synthetic
panel produced 998 across 18 frames, and READ is 398 of those. This is a
coherent picture rather than a discrepancy — but the 998-to-398 split still
needs confirming, since it is the one step not documented anywhere.

---

## Consequences for the build

| Finding | Action |
|---|---|
| F11 routing | Add `is_in_qre_base` from the 17 QRE base rules. Blocks trustworthy banners. |
| F12 screener | Document; report screen-out-violating responses as a panel-fidelity metric |
| F9 ELEMENT1 | Add `categorical` metric kind; suppress MEAN/BOT/B2B on 15 items |
| F10 theatre | Per-question base rule: exclude punch 6, add T3B |
| F8 | Confirmed correct by the QRE. No change. |

F9 and F10 were the two questions holding up the banner mart. **Both are now
answered by the questionnaire itself**, so the mart is unblocked on those.
F11 is new and larger, and needs a decision on which base the banners report.
