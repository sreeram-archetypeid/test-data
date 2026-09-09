# ABR-HTR wave — what the first full run returned

Every number below came out of `./run_all.sh /path/to/abr-repo` against the three exports as
committed. Reproduce with that one command; nothing here was typed in by hand.

---

## 1. Six export defects to raise with whoever produces the files

These are not analysis choices. They are things wrong in the data that will produce wrong
numbers if nobody is told.

**1. Option-code direction is inconsistent within a single file.** `KPLIKE2` runs 1 = best
(`1. I liked it a lot!`); `KPWANT`, four columns later in the same file, runs 5 = best
(`5. I really want to see it`). Any pipeline carrying over the Fatal Fury convention of
"top box = code 1" reports the bottom box as the top box on roughly half this battery.

**2. Twenty questions print a scale point inside the label that runs opposite to the option
code.** The whole adult `POSTATT` and `TREFFECT` battery is `1. 5 – To a very great extent`
… `5. 1 – Not at all`. Ranking by code inverts every one of them. 22 questions print a point;
20 run backwards against the code.

**3. Four `TRCONT` questions carry the wrong option list.** The question asks *"do you think it
showed too little, the right amount, or too much"* and the options supplied are an
agree/disagree battery (`Strongly agree` … `Strongly disagree`). There is no honest ranking of
that pairing, so stage 3 refuses to produce one and flags it. **Q34–Q37 of the adult file are
unreportable until the option list is fixed.**

**4. Adult Q33 is a byte-identical duplicate of Q32** — same `TREFFECT` statement, asked twice.
272 of 273 personas answered both identically. Reporting both double-counts one statement in
the battery. (The single disagreement is a 99.6% intra-interview consistency read, which is
worth keeping.)

**5. Skip logic was not applied.** All 273 personas answered `GUARD2` (ages of your children),
`CDECIS`, `CCOMFORT`, `PCGEN`, `CBBINT` and *both* the `[PARENT PATH]` and `[NON-PARENT PATH]`
recommend questions — including the 85 who had just said they are not parents. The bases on
those seven questions are invalid as they stand.
The personas partly corrected it themselves: **162 prose answers read "N/A – I am a parent"**
or similar. Stage 5 counts those separately from unscored, because they are evidence about the
base, not answers the rubric failed to read.

**6. `aat_pre_concept_interest_pct` is a cohort fixture, not a measurement.** It takes 5
distinct values across 273 adult personas (157 of them identical). `aat_interest_delta` is
therefore post-interest minus a constant and is not independent evidence of a lift.
`aat_methodology_data` is empty in all three files.

Smaller, handled, worth knowing: `archetype_gender` case drift (`MALE`, `FEMALE`, `female`),
age arriving as prose (`9 years old`), income as free text, and one option code carrying two
different labels (adult Q25, where a stray "Neither agree nor disagree" sits on printed
point 3 — dense ranking keeps it from turning a 5-point scale into a 6-point one).

## 2. The kids' "age effect" is mostly the instrument again

K3 asks 3-point scales where K9 asks 5-point ones for the same construct, exactly as T1/T23
did. Raw top box across the two panels manufactures collapses that the latent read does not
support:

| construct | K3 pts | K9 pts | K3 TB | K9 TB | raw gap | latent gap | verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| `KPFUN` (funny) | 3 | 5 | 68.0% | 4.8% | **−63.2** | −20.4 | scale artefact |
| `KPTIL` (…) | 2 | 4 | 92.0% | 40.8% | −51.2 | −19.2 | **option sets differ — not comparable** |
| `KPLOOK` (exciting) | 3 | 5 | 76.0% | 30.4% | −45.6 | −10.4 | scale artefact |
| `KPSCAR` (scary) | 4 | 5 | 64.0% | 30.4% | −33.6 | −1.5 | scale artefact |
| `KPUND` (understood) | 2 | 2 | 88.0% | 54.4% | −33.6 | −33.6 | **option sets differ — not comparable** |
| `KPSHOW` (showed too much) | 2 | 4 | 93.8% | 67.2% | −26.6 | −13.3 | scale artefact |

`KPFUN` and `KPLOOK` do carry a real age difference after equating (−20 and −10 latent
points), but a fifth to a third the size the raw numbers suggest. Three constructs cannot be
compared at all: same construct, same or similar point count, **no shared option wording**
(K3's `KPUND` offers "Easy / Some parts were hard" where K9 offers "Very easy / Mostly easy").
Full table in `out/cross_panel_equated.csv`.

## 3. Generation variance, measured for the first time

31 of K3's 36 questions and 39 of K9's 40 are worded identically to the prior wave's T1 and
T23, on disjoint personas. That is an independent re-run of the same instrument — the thing
the prior wave's README recorded as *unmeasured*.

| pair | matched constructs | rank-order ρ | mean abs. latent Δ | largest move |
|---|---:|---:|---:|---|
| K9 ↔ T23 | 19 | 0.691 | **8.8 pts** | scary/upsetting, 94.8 → 75.8 (−19.0) |
| K3 ↔ T1 | 14 | 0.530 | **5.9 pts** | title liking, 74.4 → 92.0 (+17.6) |

**Read this as a caution, not a pass.** Rank order survives moderately well (ρ ≈ 0.53–0.69),
which supports rank-based reporting. Levels do not: a mean absolute movement of 6–9 latent
points between two runs of the same instrument means **any single-run level carries at least
that much run-to-run uncertainty on top of its sampling interval**, and no confidence interval
in the banner currently accounts for it. Constructs that moved most — scary/upsetting, title
liking, kids-and-grown-ups-both-enjoy — are the least safe to quote from one run.

## 4. What the panel gets right: known-answer accuracy

| panel | question | fact | accuracy |
|---|---|---|---:|
| AD | `RETITLE` | title is *Air Bud Returns* | 100.0% (273/273) |
| AD | `DRELEASE` | release is January 22, 2027 | 99.6% (272/273) |
| AD | `DLOC` | available first in theatres | 100.0% (273/273) |
| K9 | `KPRSE` | available first in theatres | 100.0% (125/125) |
| K3 | `KPRSE` | available first in theatres | 96.0% (24/25) |

Stimulus comprehension is essentially perfect across all three panels. Combined with §3, the
picture is consistent: **these panels read the stimulus reliably; what needs an anchor is the
level of their evaluations, not their comprehension of what they saw.**

## 5. Themes — and the one the closed-ends still cannot see

Incidence is per persona, within the question role, so these are answers to "what did you
raise when asked".

**Unprompted dislikes** (`KPNL` / `TRREDUC` / `DNOGO` / `CCCONC`):

| theme | AD | K3 | K9 |
|---|---:|---:|---:|
| Clown / animal-control menace | 42.9% | **88.0%** | 59.2% |
| Sad or upsetting moments | 1.1% | **52.0%** | 24.8% |
| Predictable / formulaic | **26.7%** | 0.0% | 1.6% |
| Audio / sensory load | 1.5% | 36.0% | 12.8% |
| Pacing / length | 0.4% | 8.0% | 9.6% |

Two clean, actionable reads. **The clown animal-control officer is the single biggest volunteered
negative in the study, and it lands hardest on the youngest children** — 88% of the 4–6s raised
it unprompted (n=25, so counts: 22 of 25). Adults' leading complaint is a different one
entirely: predictability, at 26.7%. Among the K9 children who reached the scary probe, the
clown appears in **100%** of answers.

**The audio/sensory theme recurs.** Across all open ends it reaches 46.5% of adults
(127/273), 40.0% of K3 (10/25) and 33.6% of K9 (42/125) — the same order as the prior wave's
40–44%. It is still invisible to the closed-ends: no option in this questionnaire captures
sound load either. Keep coding it, or keep missing it.

**One codeframe gap the clustering found.** Cluster #0 (n=490 verbatims, 47% covered by the
codeframe) is adults saying the trailer *"tells you exactly what you're getting"* — clarity as
a positive, not predictability as a negative. Added as `CLARITY_KNOWN`; it correlates
positively with intent while `PREDICTABLE` correlates negatively, so they are two different
things and collapsing them would cancel a real finding.

## 6. Headline metrics that only exist as prose

Ten adult metrics have no closed-end. Scored against `conf/prose_rubrics.json`, 75% of
applicable answers resolve; the remainder are listed in `out/prose_unscored.csv`.

| metric | base | scored | top box | top-2 | agreement with `aat_*` |
|---|---:|---:|---:|---:|---|
| `ECHAPPEAL` appeal to a child | 273 | 194 | 96.4% | 100.0% | — |
| `ECHREQ` child would ask to see it | 272 | 231 | 85.7% | 92.2% | — |
| `POSTAPPEAL` overall appeal | 273 | 222 | 76.1% | 92.8% | **98.2%** |
| `PRECO` recommend (parent path) | 242 | 203 | 74.9% | 86.7% | — |
| `DSTREAM` watch at home later | 273 | 212 | 69.8% | 81.1% | — |
| `DTHEAT` pay to see in a theatre | 273 | 239 | 56.5% | 79.9% | **75.3%** |

The two agreement columns are the useful part: the rubric and the generator's own `aat_*`
verdict agree on overall appeal for 98.2% of personas, and on theatrical intent for only
75.3%. **Appeal is being read the same way by two independent routes; theatrical intent is
not** — and theatrical intent is the number a distributor cares about. That disagreement is
where the AI pass (`out/load/08_ai_prose_score.sql`) should be pointed first.

## 7. What travels with theatrical intent

Rank correlations, adult panel, n=239. Direction and ordering only — n=273 with
balanced-by-design demographics does not support a causal or a significance reading.

| ρ | feature |
|---:|---|
| **+0.744** | "worth seeing on a large movie-theatre screen" (`POSTATT` Q25) |
| +0.602 | "enjoyable for both children and adults" (`POSTATT` Q24) |
| +0.597 | "made me curious what happens next" (`TREFFECT` Q30) |
| +0.553 | "feels unique and different from other family movies" (`DIFFER` Q43) |
| +0.497 | title liking (`TITLEPREF` Q56) |
| **−0.406** | mentions predictable / formulaic (theme) |
| **−0.343** | mentions cost / ticket price (theme) |

The two detractors are the ones to act on, because both are addressable in marketing rather
than in the film: predictability (26.7% of adults raise it unprompted) and ticket cost.

## 8. Before anything is published

- `out/scale_review_queue.csv` — **5 questions** stage 3 would not resolve: the four broken
  `TRCONT` items and the duplicate-label Q25.
- `out/prose_unscored.csv` — 25% of applicable prose answers.
- `out/uncoded_verbatims.csv` — 875 verbatims the codeframe does not touch.
- `out/banner.csv` — **969 of 1,508 cells sit below n=30** and carry a base flag. K3 cannot
  carry percentages at all at n=25.
- The replication numbers in §3 are the honest error bar on every level in §6 and §7. Add
  them to any single-run figure before it reaches a deck.
