# ABR-TSR "Air Bud Returns" — Synthetic Kids Panel: Data Assessment

**Study:** `ABR-TSR_RETURN_v4_K` — trailer concept test, synthetic child archetype panel
**Files assessed:** 2 wide exports (`_T1`, `_T23`), Drive folder `1V3Fd8vtoIwaG0CavZ87EpeixZTeEsKVk`
**Total sample:** n = 152 personas (43 + 109)
**Status:** Assessment only. **Do not build a banner from these two files as they stand** — see §4.
**Method:** every number below was measured from the full files, not sampled or estimated.
Reproduce with `python3 analysis/profile_abr_tsr.py T1.csv T23.csv`.
**Last updated:** 2026-09-04

---

## 0. Read this first — the one-paragraph version

The trailer tests **well**: appeal is ~84% top-2-box and it is stable across both age bands;
comprehension is essentially perfect; the dog and the basketball are the twin hooks. Two things
matter more than the scores. First, **the two files are different instruments** — they use
different scale granularity for the same questions (2–3 points for ages 4-7 vs 5 points for
ages 8-12), so a naive top-box comparison manufactures a 37–54 point "collapse in appeal with
age" **that does not exist**. Second, **the strongest negative in the study is invisible in the
closed-end data**: 40–44% of personas volunteered an audio/sensory complaint (yelling coach,
buzzer, loud mix) and there is no closed-end option anywhere in the questionnaire that captures
it. A banner built on the closed-ends alone would report "91% not scary, 80% not too long" and
miss the single most consistent, most actionable finding. That is the case for semantic
analysis — not as a nice-to-have, but because the quant instrument structurally cannot see it.

---

## 1. Source inventory (measured)

| | `_T1` | `_T23` |
|---|---|---|
| Drive CSV id | `1sfGiYvOKl5y8EAn3gAEefqvXFrLySWvd` | `17NjjrL7j2_j-vMgiCshxVUSatXzFkI9v` |
| Bytes | 462,524 | 1,261,620 |
| Rows (personas) | **43** | **109** |
| Columns | 312 | 333 |
| Questions | 38 | 41 |
| Persona groups | `ABR-F3-K1`…`K4` | `ABR-F3-K5`…`K9` |
| Ages present | 4, 5, 6, 7 | 8, 9, 10, 11, 12 |
| Closed-end / open-end | 31 / 7 | 33 / 8 |
| Closed-end blanks | **0 (0.0%)** | 66 (1.8%) |

Each dataset exists in the folder **twice** — as a Google Sheet and as a CSV. There are 4 Drive
objects but only **2 datasets**. The XLSX copies supplied directly were verified byte-for-byte
equivalent in content to the Drive CSVs (identical row counts, column lists and `archetype_id`
sets), so there is one canonical dataset per file.

**Persona overlap between the two files: zero.** 0 shared `archetype_id`, 0 shared
`archetype_name`, 0 shared `group_name`. These are **disjoint samples, not repeated measures** —
you cannot track a persona across instruments, and nothing can be paired.

### 1.1 `group_name` is not a segment — it is age

| group | K1 | K2 | K3 | K4 | K5 | K6 | K7 | K8 | K9 |
|---|---|---|---|---|---|---|---|---|---|
| age | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
| n | 2 | 4 | 19 | 18 | 22 | 26 | 26 | 28 | 7 |

`group_name` and `archetype_age_range` are **perfectly collinear**. Do not present them as two
different banner cuts — it is the same cut twice, and it will read as corroboration when it is
duplication.

---

## 2. What the data actually is

Type codes (derived from fill patterns, consistent across both files):

| `Q*_type` | Meaning | Channel populated |
|---|---|---|
| `1` | Open end | `Q*_qual` only |
| `4` | Single select | `Q*_selected` only |
| `5` | Multi select, "pick up to 3", pipe-delimited | `Q*_selected` only |

**`Q*_rating` and `Q*_rating_label` are empty in 100% of cells in both files** — 0 of the 6,103 rating cells that exist in the two files populated. All quantitative signal exists **only as English label strings**
in `Q*_selected`.

This breaks the convention the existing `BIGQUERY_MIGRATION_PLAN.md` is built on. That plan's
scale machinery (§2.6) assumes numeric option codes with `1 = best/top`, and derives Top Box as
`option_code = 1`. **There are no option codes in this export.** Top-box logic here has to be
driven by an explicit, per-question, hand-authored label→rank mapping. That mapping is the single
highest-risk artefact in the whole build, and it does not currently exist.

Multi-selects are clean: pipe-delimited, and **zero** respondents exceeded the "up to 3" rule.

---

## 3. Data-quality findings (all measured, all must be handled)

| # | Issue | Evidence | Handling |
|---|---|---|---|
| **N1** | **Scale granularity differs between files for the same construct** | 13 of 14 matched constructs mismatch. "Liked trailer": T1 = 2 points, T23 = 5 points. "Root for character": T1 = **1 point** (100% gave the same answer) vs T23 = 4 | Never compare raw top-box across files. Collapse to a common coarse scale first (§4.1) |
| **N2** | **No numeric codes at all** | `rating`/`rating_label` 0% populated | Author an explicit label→rank map per question; version it in git |
| **N3** | **Generation-harness leakage into data cells** | `T23` `Q10_qual` (6,306 chars) and `Q47_qual` (5,346 chars) contain the raw LLM orchestration JSON — `mixtureOfExperts`, expert IQ scores, self-critique, and a `residualRisks` note admitting *"the inclusion of a raw JSON snippet inside the narrative response might break rigid external parsers"* | Quarantine both cells. **Do not** feed to semantic analysis |
| **N4** | **Missingness is a generation failure cluster, not non-response** | All 66 blanks come from **6 of 109** personas; 4 of the 6 are in group `K7` (age 10). Jaquan=16 blanks, Peter=12, Misael=12, Timothy=9, Wm=9, Eda=8 | Treat these 6 as partial completes. Decide explicitly: re-run or exclude. Do **not** let them silently reduce per-question bases |
| **N5** | **Skip logic was not applied** | Q28 ("*IF Scary is greater than a little*, what looked scary?") was answered by **43/43** and **109/109**. Only **1** persona per file was actually eligible. T1 Q29 same | Q28/Q29 bases are ~98% invalid. Either re-base to the eligible n=1 (unreportable) or reclassify Q28 as an unconditional probe |
| **N6** | **Q3 is not a question** | "Next, you will watch a movie trailer…" — an instruction screen, yet it carries 152 open-end "responses" | Drop from all analysis. It is not data |
| **N7** | **Race labels fork on separator** | `Asian / Pacific Islander` (1) vs `Asian or Pacific Islander` (12); `Latino / Hispanic` (38) vs `Latino or Hispanic` (1); `Black / African American` (23) vs `Black or African American` (1) | Normalise before any cut, or 3 banner columns silently split into 6 |
| **N8** | **Adoption category forks on plural** | `Early Adopter` (27) vs `Early Adopters` (10); `Innovator` (17) vs `Innovators` (4); `Laggard` (6) vs `Laggards` (2) | Singularise |
| **N9** | **Option-label punctuation drift within a file** | T23 Q16 = `A little bit.` / `Pretty much.` (trailing period) but Q18 = `A little bit` / `Pretty much` (none) — same underlying scale | Normalise on a trimmed, punctuation-stripped grouping key; keep raw |
| **N10** | **Curly apostrophes** | 3 labels: `I don’t know`, `I don’t remember`, `I’m not sure` (U+2019) | Preserve raw; normalise only in the derived key |
| **N11** | **`archetype_income_range` is free text** | **117 distinct values across 152 personas.** `Dependent (Household: $65,000)`, `Dependent (Household Income: Varies)`, `$50,000 - $75,000 (Household)`, and for one 10-year-old a bare `$50,000 - $70,000` | Unusable as a cut without parsing to numeric bounds. Not worth it at n=152 |
| **N12** | **`archetype_political_affiliation` has 21 spellings of "n/a"** | `None`, `N/A`, `Not Applicable`, `Not applicable (Minor)`, `None (Child)`, `N/A - Minor`, `Unspecified (Child)`, … plus 23 blank | Collapse to a single null. It carries no information for minors |
| **N13** | **Adult-schema columns applied to children** | `archetype_marital_status` = `single` for 152/152; `archetype_children_status` = `no_children` for 152/152; `archetype_children` **100% empty**; `archetype_field_of_study` 43% blank | Zero-variance / empty columns. Drop, don't report |
| **N14** | **Occupation double-encoded** | `5th Grade Student` (22) vs `Student (5th Grade)` (10); `4th Grade Student` (13) vs `Student (4th Grade)` (13) | Normalise to grade integer |
| **N15** | **Roleplay stage directions in 94–98% of open ends** | `[hides face in my shirt]`, `[slumps in chair]`, `[rubs eyes]`, plus `*action*` form. 296/301 (T1) and 824/872 (T23) | **Strip before any embedding or sentiment step** (§5.1). Left in, they dominate the vector space |
| **N16** | **Simulated survey fatigue rises with question position** | Fatigue markers ("*my brain is tired*", "*are we done yet*", "*my hands are tired*") reach **45%** at T23 Q50 and **37%** at T1 Q32, from ~0-1% at Q3-Q6 | Late-questionnaire open ends are systematically degraded. Weight or flag by position; do not read Q50 verbatims as considered opinion |
| **N17** | **No exact duplicate verbatims** | 301/301 and 872/872 distinct | No action — recorded so nobody "dedupes" |

---

## 4. Why a banner is not safe yet — and what to do

### 4.1 N1 is the blocking issue: the "appeal collapse" is an artefact

Comparing raw top box across the two files:

| construct | T1 top box | T23 top box | apparent gap |
|---|---:|---:|---:|
| Liked trailer | 84% | 47% | **−37** |
| Want to see | 86% | 41% | **−45** |
| Funny | 63% | 9% | **−54** |
| Exciting | 74% | 21% | **−53** |

Those numbers are **wrong as a comparison**. T1's single top box ("*I liked it a lot*") is
semantically as wide as T23's **two** top boxes ("*I liked it a lot!*" + "*I liked it!*").
Collapse them and the illusion disappears:

| construct | T1 top box | T23 **top-2** box | real gap |
|---|---:|---:|---:|
| Liked trailer | 84% | **84%** | **0** |
| Want to see | 86% | 83% | −3 |
| Tell a friend | 65% | 65% | 0 |
| Watch at home | 98% | 93% | −4 |
| Root for character | 100% | 95% | −5 |
| Kids + grown-ups | 98% | 89% | −9 |
| Ask parent → theatre | 81% | 70% | −11 |
| Exciting | 74% | 61% | −13 |
| Title liking | 74% | 57% | **−17** |
| Understand (easy) | 95% | 100% | +5 |

**Rule for the banner:** report the two age bands as **separate instruments** in separate
columns with their own bases, or pool them **only** on a collapsed positive/neutral/negative
recode. Never put raw top box for T1 and T23 in the same row of the same table.

Note also that after collapsing, **title liking (−17) and ask-parent-for-theatre (−11) are the
two genuine age declines.** Those survive the correction and are real findings.

### 4.2 The other banner blockers

1. **Every demographic cell is below reportable base.** Pooled n=152. By age: max cell 28,
   min 2. By group: identical (they're the same variable). Ages 4 (n=2), 5 (n=4) and 12 (n=7)
   cannot be shown at all. **18 of 18 age × gender cells fall under n=30.** Only three cuts
   clear n≥30: total (152), gender (77/75), and the top two race groups (76/38).
2. **Gender is balanced to a degree real samples never are** — 77/75 overall, and within nearly
   every single year of age it is 13/13, 11/11, 9/10. This is a design fixture, not a sample.
   Gender gaps here carry no sampling error in the usual sense; don't significance-test them
   as if drawn.
3. **Q28/Q29 have a ~98% invalid base** (N5) and must not appear as a normal banner row.
4. **Six partial completes (N4)** will make per-question bases wobble between 104 and 109 in
   T23 unless you fix a consistent base and state it.
5. **Label forking (N7, N8, N9)** will split banner columns silently — the table will still
   add up, which is exactly what makes it dangerous.
6. **No numeric codes (N2)** means every Top Box in the banner depends on a hand-authored
   label ranking. Unversioned, that is an unauditable number.

### 4.3 What can be reported responsibly today

- **Total-level** results per file, bases stated, scales shown verbatim.
- **Gender** at total level within each file (n≈21-22 in T1 — flag as low base; n≈54-55 in T23).
- **Two age bands** (4-7 vs 8-12) as separate instruments, or pooled on a collapsed recode.
- **Directional** language only. At n=43, a 10-point difference is inside the noise.

Everything finer than that is illustrative, not measurement.

---

## 5. Insights (measured, and what I'd actually say)

### 5.1 The trailer works, and the hooks are stable

- **Appeal ~84% positive in both age bands** (T1 top box 84%; T23 T2B 84%).
- **Intent 83-86% positive.** Advocacy ("tell a friend") 65% in both.
- **Comprehension is essentially perfect** and is the strongest result in the study:
  **95%** (T1, with 5% "some parts were hard") and **100%** (T23) said the trailer was easy to
  understand — in T23 *only* the two positive points of that scale were used at all, nobody
  picked a negative. In the open ends, 95-100% reference the basketball/sport premise, 82-98%
  the dog, and **69-79% spontaneously articulate the underdog/winning arc** without being
  prompted.
- **Title recall is high and rises with age:** 84% (4-7) → 98% (8-12) named "Air Bud Returns".
- **Distribution message landed:** 95-100% correctly recalled "in a movie theatre" first.
- **This is a cold start:** 95-98% had never heard of the film. All of the above is
  trailer-driven, not equity-driven.

**The twin hooks are the dog and the sport, and they are remarkably age-stable:**

| liked element | 4-7 | 8-12 |
|---|---:|---:|
| The sports or game parts | 72% | 70% |
| The main character | 67% | 70% |
| Friendship or teamwork | 49% | 41% |
| The jokes or funny parts | 49% | **35%** |
| The music | 9% | **22%** |

### 5.2 The finding the closed-ends cannot see — the audio mix

Coded on cleaned open-end text, the **#1 volunteered dislike in both age bands is sensory**:

| volunteered dislike (Q32) | 4-7 | 8-12 |
|---|---:|---:|
| **Loud / yelling / buzzer / noise** | **37%** | **35%** |
| Boring / slow / too long | 21% | 21% |
| Nothing / no complaint | majority | majority |

Widen to Q28 + Q32 and **44% (4-7) and 40% (8-12)** raise it. The target is specific and
consistent: the **yelling coach/referee**, the **end buzzer**, and the **music mix**.

> "The yelling man. And the music was too loud. It hurt my ears."  — age 6
> "It got kinda loud with all the cheering and the hip hop music. I like the quiet parts better." — age 9
> "the loud referee guy at the beginning maybe. i don't like when people yell." — age 10
> "The really loud buzzer noise at the end. It hurt my ears." — age 5

**There is no closed-end option in the entire study that captures this.** Of 104 distinct
closed-end options across both files, the only one touching sound is "The music" — a *liked*
element. The scary/boring/too-long/showed-too-much battery has no sensory or volume item.

Consequently the closed-ends report the trailer as **91% "not scary at all"** while **30% of
those same personas volunteered a sensory complaint in their own words** (23% in T1). That is
not a contradiction in the respondents — it is a **coverage gap in the instrument**. The kids
are not frightened; they are *overstimulated*, and the questionnaire has no box for it.

**Action:** this is the one concrete, cheap trailer note the study produces — remix the
yelling/buzzer/music bed. And add a volume/sensory item to the closed-end battery in v5.

### 5.3 The real age story: a theatrical-to-home crossover

This is the finding with money attached, and it **survives** the scale correction.

| | 4-7 | 8-12 |
|---|---:|---:|
| Prefer theatre (Q43) | **67%** | **40%** |
| Prefer to wait for home | 30% | **53%** |
| Theatre, if same-day choice (Q44) | 60% | 33% |
| Ask a parent to take them (collapsed) | 81% | 70% |
| Want to watch at home (collapsed) | 98% | 93% |

Theatrical pull **inverts** between the two age bands, while home demand stays near-universal.
Co-viewing shifts with it: "my whole family" 67% → 33%, "friends my age" 19% → **35%**, and
**10% of 8-12s would watch alone** (0% of 4-7s).

**Read:** the theatrical case is strongest on the **4-7 family outing**, sold to the parent.
For 8-12 this is a **home/streaming title with a peer-viewing angle** — and the drop in title
liking (−17) and in comedy appeal (49%→35%) points the same way. Younger skew is the
theatrical audience; don't build the theatrical campaign on the older cohort.

### 5.4 Emotional payoff shifts from delight to inspiration

| end-state emotion (Q36) | 4-7 | 8-12 |
|---|---:|---:|
| Happy | 100% | 95% |
| Excited | 65% | 47% |
| **Inspired** | 12% | **34%** |
| Bored | 0% | 6% |

Older kids want the **underdog-triumph payoff** (and 69% already predict it unprompted);
younger kids want **warmth and fun**. Two different trailer cuts are implied, and the asset
that serves both is the dog-plus-team material, not the comedy beats.

### 5.5 Persona-design observations

- `archetype_nps_score` is **pre-assigned persona metadata, not a response to this trailer**
  (values 4-10; 9s and 8s dominate; implied NPS ≈ +41). **Do not report it as a trailer
  metric.** It is an input to the simulation, not an output.
- Basketball affinity is genuinely mixed (26% "not really" in 4-7; 17% "not at all" in 8-12),
  so the strong sports-hook result is **not** an artefact of a sports-fan panel. That is a
  meaningful robustness point in the study's favour.
- `archetype_behavioral_spark_name` (32 values) and `adoption_category` are the only
  psychographic cuts with enough concentration to be worth crossing — and even the largest,
  `Emotional Resonance` (n=18), is below reportable base.

---

## 6. How to validate all of this

Validation splits into two different questions people keep conflating: **is the data internally
sound** (cheap, do it now) and **does the synthetic panel predict humans** (the only one that
licenses a real decision).

### 6.1 Internal validation — already partly run, extend it

| Check | Status | Result |
|---|---|---|
| Stated age (Q1) vs `archetype_age_range` | **run** | **152/152 match (100%)** — no persona drift |
| Title recall (Q50) vs ground truth | **run** | 84% / 98% correct — attention is real |
| Distribution recall (Q37) vs ground truth | **run** | 95% / 100% correct |
| Multi-select rule ("up to 3") | **run** | 0 violations |
| Duplicate verbatims | **run** | 0 exact duplicates |
| Skip-logic conformance | **run** | **FAILED** — Q28/Q29 asked to everyone (N5) |
| Closed vs open coherence | **run** | 23-30% contradiction on scary-vs-sensory — traced to instrument gap, not respondent error |
| Straightlining / zero-variance | **run** | T1 Q15 = **100% single answer**; T23 Q20 uses only 2 of its points |

Two checks worth adding before anyone publishes:

1. **Psychographic coherence.** Cross `archetype_behavioral_spark_name` against appeal and
   intent. A near-diagonal pattern means the authored personas actually behave like their
   labels. A scrambled one means the persona metadata is decoration — **and that is a finding
   worth reporting**, not a bug to hide. (Same logic as `BIGQUERY_MIGRATION_PLAN.md` §10.2.)
2. **Answer stability / re-run reliability.** Nothing in these two files is a replicate, so
   there is currently **no way to measure how much of any number is generation variance.**
   The Fatal Fury study got this free from its `2.1X` replicate runs. Here it must be
   commissioned: re-run ~20 personas at temperature 0 and measure agreement. **Until that
   exists, no confidence interval on any of these numbers is defensible.** This is the single
   most valuable cheap thing to add.

### 6.2 External validation — the one that actually matters

The `Final W Tabs (1)/` human benchmark in this repo (N=800 humans) is **not usable here**: it
is the Fatal Fury universe, banners `GENDER` and `QUADRANTS` (Men <35 / Women 35+ …). There is
no human child panel for Air Bud Returns in the repo.

So calibration needs one of:

- **A human kids panel** on the same trailer and the same core items — even n=100-150 would let
  you fit an offset per metric and state a calibration error.
- **Historical hold-out:** run the synthetic panel against a kids title whose real research you
  already own, and measure the gap on top-box appeal and theatrical intent.

Until one exists, the honest framing is: **these are directional, hypothesis-generating,
diagnostically useful results from a simulated panel.** They are strong enough to brief a
trailer re-cut on the audio mix; they are not strong enough to size an opening weekend.

### 6.3 Validating the semantic layer specifically

Semantic coding needs its own validation or it just launders model opinion into a table:

1. **Human-code a 100-verbatim stratified sample** (by file, question, sentiment) and measure
   agreement with the model codes. Report Cohen's κ. Below ~0.7, fix the codebook, not the data.
2. **Pin `temperature = 0`** and **version the prompt in git** — a silent prompt edit re-codes
   the entire study and nothing in the output will look different.
3. **Run it twice** and measure code stability across runs. Report it alongside the codes.
4. **Hold back the stage directions as a control:** code 50 verbatims raw and 50 cleaned. If
   sentiment moves, N15 was material and the cleaning step is load-bearing (I expect it is).

---

## 7. Semantic analysis — how I'd actually build it

You're right that this is mostly qualitative and that it is where the value is: **1,173 raw
open-end responses** (301 + 872) across **9** open-end questions — **1,019** once Q3 (the
instruction screen, N6) is dropped and the two leaked cells (N3) are quarantined. None of them
are tabulated anywhere today. The closed-ends are 104 fixed options that already missed the
study's biggest finding.

> **Caveat on the link you sent:** `docs.cloud.google.com` is blocked by this environment's
> egress proxy, so I could not read that page. The function names below are from BigQuery
> knowledge and a web search, **not** from your linked doc — confirm exact signatures against
> it before building. In particular `AI.SEMANTIC_CLUSTER` did not surface in search and I would
> not assume it exists; the embedding + `ML.KMEANS` route below is the safe equivalent.

### 7.1 Mandatory pre-step: strip the performance layer

Non-negotiable, and it is the thing most likely to be skipped:

```sql
-- 94-98% of verbatims carry roleplay stage directions (N15).
-- Left in, "[slumps in chair]" and "[rubs eyes]" dominate the embedding
-- space and every cluster comes back as a cluster of body language.
CREATE OR REPLACE TABLE abr_20_curated.verbatim_clean AS
SELECT
  archetype_id, question_key, age, age_band, gender, group_name,
  qual_text AS qual_raw,
  TRIM(REGEXP_REPLACE(
    REGEXP_REPLACE(
      REGEXP_REPLACE(qual_text, r'\[[^\]]*\]', ' '),  -- [stage directions]
      r'\*[^*]*\*', ' '),                             -- *actions*
    r'\s+', ' ')) AS qual_clean,
  -- keep what we stripped: fatigue is a real signal, just not an opinion
  REGEXP_CONTAINS(LOWER(qual_text),
    r"tired|are we done|can i go|brain is tired|hands are tired") AS is_fatigued,
  question_position
FROM abr_10_raw.response_long
WHERE qual_text IS NOT NULL
  AND question_key != 'Q3'                       -- N6: instruction screen
  AND LENGTH(qual_text) < 3000                   -- N3: quarantine leaked JSON
  AND NOT REGEXP_CONTAINS(qual_text, r'"mixtureOfExperts"');
```

That `WHERE` clause is doing four of the §3 findings' work at once. `qual_raw` is retained —
never overwrite the source.

### 7.2 Structured coding — the highest-value query

`AI.GENERATE_TABLE` over the 1,019 clean verbatims, forcing a fixed codeframe. This is the step that turns
qual into something a banner can hold:

```sql
CREATE OR REPLACE TABLE abr_30_marts.mart_verbatim_coded AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `abr_30_marts.gemini_endpoint`,
  (SELECT archetype_id, question_key, age_band, gender, qual_clean,
     CONCAT(
       'Code this open-end from a children''s movie-trailer test. ',
       'The respondent is aged ', CAST(age AS STRING), '. ',
       'Question: ', question_text, '\nResponse: ', qual_clean
     ) AS prompt
   FROM abr_20_curated.verbatim_clean),
  STRUCT(
    'sentiment STRING, primary_theme STRING, secondary_theme STRING, '
    || 'mentions_sensory_overload BOOL, mentions_dog BOOL, '
    || 'mentions_sport BOOL, mentions_predictability BOOL, '
    || 'is_actionable_note BOOL, intensity INT64' AS output_schema,
    0.0 AS temperature)                  -- determinism is not optional here
);
```

`mentions_sensory_overload` is in that schema deliberately — it is the variable the closed-end
instrument never had, and the reason to do this at all. Once coded, it becomes a normal banner
row and a normal driver.

### 7.3 Clustering — let the themes emerge rather than imposing them

Use this to check whether your codeframe missed something, not instead of §7.2:

```sql
-- 1. embed (task_type matters: CLUSTERING, not SEMANTIC_SIMILARITY)
CREATE OR REPLACE TABLE abr_30_marts.verbatim_emb AS
SELECT * FROM ML.GENERATE_EMBEDDING(
  MODEL `abr_30_marts.text_emb`,
  (SELECT archetype_id, question_key, age_band,
          qual_clean AS content
   FROM abr_20_curated.verbatim_clean
   WHERE question_key IN ('Q4','Q30','Q32','Q31')),
  STRUCT('CLUSTERING' AS task_type));

-- 2. cluster. k=6-8 for 1,173 docs; inspect, don't trust blindly
CREATE OR REPLACE MODEL abr_30_marts.theme_clusters
OPTIONS(model_type='KMEANS', num_clusters=7,
        distance_type='COSINE') AS
SELECT ml_generate_embedding_result FROM abr_30_marts.verbatim_emb;
```

Then `AI.GENERATE` a label per centroid, and **cross clusters against the closed-ends**. A
cluster that predicts intent but has no closed-end equivalent is exactly the sensory finding
repeating itself — that is the pattern to hunt for.

`VECTOR_SEARCH` over the same embeddings is then how you pull evidence verbatims for a deck:
give it "the music was too loud and it hurt my ears" and it returns the 20 nearest real
responses, ranked. Far better than grepping.

### 7.4 Two hard warnings

1. **Semantic analysis does not fix the base sizes.** Coding 1,019 verbatims from **152**
   personas produces lots of rows, not more respondents. A theme at "38% of verbatims" is still
   ~16 children in T1. The row count will *feel* like n=1,019 in a table and it is not.
2. **The panel is synthetic, so the model is partly scoring its own output.** Sentiment coding
   of LLM-generated verbatims by an LLM shares failure modes — pleasantness bias especially,
   which would inflate an already very positive result. This is why §6.3's human-coded sample
   is a requirement, not a formality.

---

## 8. Open questions for the research lead

1. **What are `T1` and `T23`?** Ages and question branches both differ. Is `T23` "trailers 2+3"
   (one instrument, pooled), or the 8-12 instrument, or two cuts merged? The answer changes
   whether §4.1's pooling is legitimate at all. Nothing in the files states it.
2. **Was the 2-3 point scale for ages 4-7 a deliberate age adaptation?** If yes, N1 is a design
   feature and the collapsed comparison in §4.1 is the correct permanent reporting frame. If
   accidental, T1 should be re-run on the 5-point instrument.
3. **Why is T1 n=43 against T23 n=109,** and why are ages 4 (n=2), 5 (n=4) and 12 (n=7) so
   thin? Was a target quota missed, or is the design intentionally weighted to 6-11?
4. **The 6 broken personas (N4) — re-run or exclude?** 4 of 6 sit in `K7`; worth checking
   whether that generation batch failed.
5. **Is `archetype_nps_score` an input or an output?** Read as pre-assigned metadata here. If
   it is meant as a trailer response, the pipeline is mislabelling it.
6. **Is there a human kids benchmark** for this or any comparable title? Without it §6.2 cannot
   run and every number stays directional.
7. **Was Q28's skip logic supposed to fire?** If it was meant to be unconditional, the question
   text needs rewriting; if conditional, the harness ignored it and that is a platform bug
   affecting every study, not just this one.

---

## 9. Recommended sequence

1. Answer §8.1 and §8.2 — they gate everything downstream.
2. Normalise N7-N14; quarantine N3; drop N6; re-base N5.
3. Author and **version** the label→rank map (N2). Nothing reportable exists before this.
4. Publish **total + gender, per file, bases stated**. Nothing finer.
5. Run §7.1-§7.2. Human-validate 100 verbatims (§6.3) before believing the codes.
6. Commission the re-run reliability test (§6.1.2) — it is cheap and it is the only thing that
   turns these point estimates into ranges.
7. Only then attempt human calibration (§6.2) and anything resembling a forecast.

**The one thing that can go out early, with confidence:** the audio-mix note in §5.2. It is
consistent across both age bands, volunteered rather than prompted, specific enough to action,
and it does not depend on any of the contested scale decisions.
