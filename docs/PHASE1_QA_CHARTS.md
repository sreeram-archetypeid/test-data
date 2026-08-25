# Phase 1 QA charts — designed, not built

**Status: deferred by decision.** Phase 1 passed every gate (22/22 mart checks,
44/44 DQ, Gates 1–6 green), so this visual sign-off was judged unnecessary
re-verification. This document keeps the design so it can be picked up later
without re-deriving it.

Every number below was measured from the 12 source CSVs, by a parse that
reproduces Gate 4 exactly (40,178 rows / 398 personas / 91 questions / 36,218
primary rows). So these are not mockups with placeholder values — they are what
the charts would show.

**Where this would live:** `notebooks/phase1_qa.ipynb`, run from VS Code against
BigQuery (not BigQuery Studio — a committed notebook is reviewable in a PR and
re-runnable by anyone; a console notebook is neither). Aggregate in SQL, plot
locally; nothing here needs a cloud runtime.

---

## 1. Replicate agreement — the one worth building

Section 2.1 was asked **twice** to the same 198 personas (cohorts G.2 and S.1),
producing 3,960 `(persona, question)` keys with two rows each. Whether the two
runs agree had never been checked.

```
Screener 2 (country)  ████████████████████ 100.0%  ┐
PARENT2               ████████████████████ 100.0%  │ facts
RECENTFILM1           ████████████████████ 100.0%  │
PARENT1               ███████████████████▉  99.0%  ┘
Screener 1            ██████████████████▉   94.4%
GFAN1 (6-pt fandom)   ████████████████▍     82.4%  ┐ graded
ACTIVITIES (6-pt)     ████████████████      80.1%  ┘ opinions
                                     overall 86.7%
```

| | |
|---|---|
| Exact agreement on `primary_code` | **86.7%** (3,432 / 3,960) |
| Mean absolute difference when they differ | **1.10** scale points |

**Why it matters:** if a persona answers the same question twice and gives a
wildly different answer, the panel is not modelling a stable person. What the
data shows is the opposite — **facts are perfectly stable and graded opinions
drift by about one punch.**

**This answers an open research-lead question** (Appendix A item 5). The
standalone 2.1 files are *not* discarded pilots: a deterministic re-run would
agree ~100%, a broken one would look random. 86.7% with adjacent-punch drift on
scales and 100% on facts is the signature of a genuine re-ask. Recorded as F15.

Chart form: horizontal bars for agreement per question, plus a second panel
showing the signed difference distribution (expect mass at 0 and ±1).

---

## 2. Where the 5,587 blank answers come from

```
open-end questions    ████████████████████████  4,574   no options to pick
numeric rating 0-10   ███                          596   answer is a number
"none of the above"   ██                           417   a real answer
```

**Why:** 5,587 NULL `primary_code` values look like missing data. Only the third
group involves a person choosing something — and they chose "none", which must
count in the base but never in a top-box numerator. This makes the D9 sentinel
rule and the F5 code-prefix fix visible in one picture.

---

## 3. Question type × scale length

|  | 1 | 2 | 3 | 4 | 5 | 6 | 7–20 | total |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| **ordinal_scale** | · | 2 | 11 | 34 | · | 7 | · | **54** |
| **categorical** (ELEMENT1) | · | · | 15 | · | · | · | · | **15** |
| **multi_select** | · | · | · | · | 1 | · | 8 | **9** |
| **single_option** | 2 | · | · | · | · | · | · | **2** |
| | | | | | | | | **80** |

`numeric_rating` (1) and `open_end` (10) have no option rows, so 80 + 11 = 91.

**Why:** two things must be visible. Ordinal scales occupy only **{2, 3, 4, 6}** —
there is no 5-point scale anywhere in this study, so any formula assuming one is
wrong on every question. And multi-selects run out to 20 options, where "top box"
has no meaning at all.

**This is where top-box correctness shows up.** The mechanics were fixed during
Phase 1 (Gate 5 gates the box flags on `metric_kind`; M-06/M-07 keep them off
non-ordinal questions). The chart confirms the classification; the actual
top-box *figures* are Phase 3 work.

---

## 4. Pipeline waterfall

```
raw CSVs (1 row per persona per file)        1,392  ▏
   ↓ unpivot 20 / 35 / 36 question blocks
fct_response (persona × run × question)     40,178  ████████████████████
   ↓ set aside the second 2.1 run           −3,960
primary rows (one per persona × question)   36,218  ██████████████████
```

**Why:** the whole shape of the pipeline in one glance — how 1,392 very wide rows
became 40,178 narrow ones, and where the duplicate run is set aside rather than
deleted.

---

## 5. QRE base impact, at both grains

```
                persona grain        row grain
PARENT2         291 ███████████      435 ██████████████   ← doubles
POLORIENT        60 ██                60 ██
URG2             51 ██                51 ██
ELEMENT2         51 ██                51 ██
LIKE             43 █▌                43 █▌
DISLIKE          26 █                 26 █
PRELIKE1/2      5+5 ▏                5+5 ▏
RECONFIRM         0                    0
                532                  676
```

**Why:** the questionnaire skips questions for people who shouldn't see them; the
synthetic panel asked everyone (F11). This shows exactly who was over-asked.

The two columns matter: `PARENT2` sits in the twice-run section, so its 291
out-of-base **personas** become 435 **rows**. That persona-vs-row distinction is
where hand-written expectations went wrong twice during Phase 1 — showing both
side by side is the point of the chart.

---

## 6. Banner cut distributions

```
RACE     White Non-Hisp  ████████████████ 214
         Hispanic        █████             73
         African Amer.   ████              63
         Asian           ███               41
         Unknown         ▌                  7
         Other           ·                  0  ← must stay empty (F13)

INCOME   <75K            ███████████      152
         $75K-$125K      █████████████    178
         $125K+          █████             68
```

**Why:** these are the columns every banner report is built from. The `Other = 0`
bar is a tripwire — source race values arrive with a typo (`Latico / Hispanic`),
seven empty strings, and two spellings of Asian. Anything the normalisation rule
fails to recognise lands in `Other`, so an empty bar means the rule still covers
every value in the data.

---

## Design notes for whoever builds this

- **Do not hard-code expected values.** Three separate rounds of Phase 1 errors
  were hand-typed expectations that disagreed with a correct pipeline. The final
  cell should read the latest run from `ff_30_marts.dq_results` — which already
  stores `(run_ts, dq_id, assertion, actual, expected, passed)` — and assert
  every headline figure against it. One source of truth.
- **No `%%bigquery` magics.** They must be the literal first line of a cell,
  which is a trap that already cost a debugging round. Pass SQL as a Python
  string through a small helper so every cell is valid Python.
- **Strip outputs before committing** (`nbstripout`, or Clear All Outputs).
  Saved output embeds fully-qualified table names, and therefore the project ID.
- Palette already validated: `#2a78d6` / `#eb6834` (worst adjacent ΔE 24.7
  protan, 33.6 normal). Charts 3 and 6 need more than two categories, so extend
  it deliberately rather than by eye.

## Explicitly out of scope

POSTINT top-box by creative, CHARDES/STORYDES incidence, and the
synthetic-vs-human W-Tabs comparison. Those are analysis, not QA — see
`docs/MIGRATION_ROADMAP.md`.
