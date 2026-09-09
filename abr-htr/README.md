# ABR-HTR wave — load, land, and analyse

Tooling for the three new exports of the **`42p.0.0-ABR-HTR-09-01-1`** wave, doing for HTR
what was already done for ABR-TSR: get the data landed in a shape you can query, decide what
the scales mean, then run the semantic and theme analysis on top.

Everything here is **stdlib Python 3** — no pandas, no numpy, no network. It runs on the
exports in place and writes to `out/`.

```bash
./run_all.sh /path/to/abr-repo          # six stages, ~20 seconds on the full wave
# then read out/HTR_WAVE_ASSESSMENT.md
```

---

## What the wave is

| Panel | File | Personas | Questions | Notes |
|---|---|---:|---:|---|
| **AD** | `42p.0.0-ABR-HTR-09-01-1 — Results.csv` | 273 | 83 | **Adults** — 188 parents / 85 non-parents. New: the prior wave had no adult panel at all |
| **K9** | `…-K9-09-01-1 — Results.csv` | 125 | 40 | Kids 7–12 |
| **K3** | `…-K3-09-01-1 — Results.csv` | 25 | 36 | Kids 4–6 |

423 personas, 28,559 question-answer facts, 7,277 verbatims. Zero persona overlap between the
three files, and none with the prior wave — disjoint samples, nothing can be paired.

## Five ways this wave differs from ABR-TSR, and what each one costs

1. **Option codes now exist, and their direction is not fixed.** `KPLIKE2` runs 1 = best;
   `KPWANT` in the same file runs 5 = best. A global "top box = code 1" rule reports the
   bottom box as the top box on a large part of the battery.
2. **22 questions print a second scale number inside the label** (`2. 4 – To a great extent`)
   and on **20 of them it runs opposite to the option code**. The printed point is the
   questionnaire's scale; the code is an artefact of option ordering.
3. **Ten adult headline metrics arrive as prose** with no closed-end anywhere — appeal, appeal
   to a child, likelihood a child asks to see it, recommend (both paths), theatrical intent,
   streaming intent, category interest. Until they are scored they cannot enter a banner.
4. **A new 34-column `aat_*` diagnostic block**, with `aat_diagnostics_json` as its nested
   source of truth. Useful, and it doubles as an independent second reading of some of the
   same constructs, which is how stage 5 checks itself.
5. **K3 and K9 replicate the prior wave's wording** (31 of 36 and 39 of 40 questions) on
   disjoint personas. The prior wave recorded generation variance as *unmeasured* because
   nothing in it was a replicate. This wave is one.

`FINDINGS.md` has what the first full run actually returned, including the defects worth
raising with whoever produces the exports.

---

## Stages

Run order is file order. Each stage reads the previous stage's output, and each one refuses
to guess quietly — anything unresolved lands in a review file rather than a default.

| Stage | Script | What it does | Gate before moving on |
|---|---|---|---|
| 1 | `tools/01_profile.py` | Measures the exports; writes `HTR_WAVE_ASSESSMENT.md`, `manifest.json` (reconciliation targets) and `dq_findings.csv` (every assertion, PASS/FLAG/FAIL) | No FAIL findings |
| 2 | `tools/02_land.py` | Wide → long. `dim_archetype`, `dim_aat`, `dim_question`, `dim_question_option`, `fct_response`, `fct_response_option`, plus the BigQuery load artefacts in `out/load/` | Reconciliation OK: 423 personas, 28,559 facts |
| 3 | `tools/03_scale_map.py` | Decides what top box means per question: polarity, rank basis, sentinels, 0–100 latent score, equated boxes | Read `scale_review_queue.csv` before publishing |
| 4 | `tools/04_semantic_themes.py` | Verbatim hygiene, codeframe coding, emergent clustering, theme incidence by question role and cut | Check the codeframe-gap clusters |
| 5 | `tools/05_prose_scale.py` | Scores the prose-only metrics against `conf/prose_rubrics.json`, and cross-checks against the `aat_*` block | Coverage and `prose_unscored.csv` |
| 6 | `tools/06_analyze.py` | Banner with Wilson intervals and base flags, equated cross-panel read, replication vs prior wave, known-answer accuracy, intent drivers | — |

## The three decisions that shape every number

**Sentinels are excluded from box maths, by label, not by code.** `I'm not sure` is option
code 6 in one question and code 3 in another. Nothing here assumes the Fatal Fury convention
that sentinels sit at codes ≥ 90 — that rule is wrong on this data.

**Latent favourability, 0–100, sits alongside the raw boxes.** K3 asks 3-point scales where
K9 asks 5-point ones for the same construct, so counting boxes cannot cross them. The prior
wave's spurious "37–54 point appeal collapse with age" is exactly what that produces. Stage 6
prints raw and equated side by side, and refuses to equate at all when the two panels'
option wording does not overlap.

**Incidence is scoped to a question role.** "Does this persona mention the dog anywhere across
20 open ends" is ~100% for every theme worth having. `conf/question_roles.json` maps metas to
the read they support (`first_reaction`, `likes`, `dislikes`, `scary_probe`, …), and incidence
is reported per persona within a role, with the null-response rate ("Nothing, I loved it")
reported next to it.

## Configuration, versioned on purpose

| File | What it controls |
|---|---|
| `conf/scale_lexicon.json` | The intensity ladder, sentinel phrases, negative and mid-optimal constructs, nominal metas |
| `conf/codeframe.json` | 24 themes and 190 patterns, including `AUDIO_SENSORY` — the theme no closed-end in this questionnaire can capture |
| `conf/question_roles.json` | Which questions support which read |
| `conf/prose_rubrics.json` | The 5-point rubric for the prose-only metrics |

Edit a config, re-run the stage, diff the output. Never hand-edit anything in `out/` — it is
generated, and a hand-edit is invisible on the next run.

## Taking it to BigQuery

Stage 2 generates the load path and stages 3–5 generate the in-warehouse AI passes, all with
`PROJECT_ID` / `BUCKET` as literal placeholders. Nothing has been executed against a project.

```
out/load/00_datasets.sh           five datasets, one region
out/load/01_stage_to_gcs.sh       staging with GCS-safe object names
out/load/02_external_and_raw.sql  external tables + materialised raw (all STRING)
out/load/03_unpivot_{ad,k3,k9}.sql  generated wide→long, one SELECT per question slot
out/load/04_gate.sql              the measured row counts, asserted
out/load/05_ai_scale_rank.sql     AI ranking — only the questions stage 3 could not resolve
out/load/05b_validate_scale_map.sql  permutation, monotonicity, two-run stability, agreement
out/load/06_ai_verbatim_coding.sql   the same codeframe, in-warehouse
out/load/07_embeddings_clusters.sql  ML.GENERATE_EMBEDDING (task_type CLUSTERING) + KMEANS
out/load/08_ai_prose_score.sql       the same rubric, in-warehouse
```

The local passes are not a substitute for the AI ones. They are what makes them cheap and
checkable: you know the expected distribution before you spend a call, so a result 20 points
away is a prompt bug you can see rather than a finding you might publish.

## Limits worth stating out loud

- **K3 is n=25.** Report counts, not percentages. 969 of 1,508 banner cells fall below n=30
  and every one is flagged in `banner.csv`.
- **Scale points are the observed option universe.** Where a label prints its own scale point
  the full instrument scale is recoverable and is used; elsewhere an option nobody chose is
  invisible, which slightly compresses the latent axis.
- **Absolute levels still have no human anchor.** There is no human trailer test for this
  title. Rank order, replication and known-answer accuracy do not need one, which is why
  stage 6 leans on those three.
- **Correlations are hypothesis generators.** n=273, and the panel's demographics are balanced
  by design rather than drawn, so the usual sampling-error reading does not apply.
- **The deterministic passes are baselines.** Stage 3 leaves 5 questions for review, stage 5
  scores 75% of applicable prose. Both list what they could not do.

## Where this should live

Written on the `test-data` branch this session was pointed at, but it belongs in the **`ABR`
repo** next to `bigquery/` and `analysis/`, since the exports and the prior-wave pipeline are
there and the two studies are deliberately kept apart. Move `abr-htr/` across as-is — nothing
in it imports anything from `test-data`, and `run_all.sh` takes the data directory as an
argument.
