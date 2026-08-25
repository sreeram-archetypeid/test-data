# Phase 1 — Status & Architecture Guide

Companion to [`PHASE1_RUNBOOK.md`](PHASE1_RUNBOOK.md) (what to run) and
[`../BIGQUERY_MIGRATION_PLAN.md`](../BIGQUERY_MIGRATION_PLAN.md) (the original
design). This document explains **what exists, why each file exists, and how to
describe the pipeline to someone else.**

**Project** `archetypeid-staging` · **Region** `us-central1`

---

## 1. Status: 11 of 14 steps done, 46 assertions green

| Step | What | Status |
|---|---|---|
| 1–2 | gcloud SDK, auth, `config.env` | done |
| 3 | GCS bucket + 4 BigQuery datasets | done, all `us-central1` |
| 4 | Repo skeleton (`tools/`, `sql/`) | done |
| 5 | 12 CSVs staged to GCS with safe names | done — 12 objects |
| 6 | Raw landing | **Gate 1** — 596 / 398 / 398 = 1,392 |
| 7–8 | Wide→long unpivot, parse & clean | **40,178 rows**, 11/11 assertions |
| 9–11 | Curated dimensions | **Gates 2 / 2b / 3** — 398 / 12 / 91 / 334, 35/35 |
| **12** | **`fct_response` + `v_response_metrics`** | **next — Gate 4** |
| 13 | DQ suite DQ01–DQ16 | pending |
| 14 | Close-out + box-metric decision | pending |

### There is no machine-learning model yet, by design

"Model" so far means **data model** — the table structure. BigQuery ML (driver
regression, k-means segmentation, AI-coded verbatims) is **Phase 4** and cannot
begin until Gate 4 passes. Nothing currently predicts or scores anything.

---

## 2. What exists in Google Cloud

### Cloud Storage

`gs://archetypeid-staging-arena-ff/arena-ff/read/v1/` — 12 objects:

```
read_g_gr1_s2_1x.csv   read_g_gr1_s2_2.csv   read_g_gr1_s2_3.csv
read_g_gr2_s2_1.csv    read_g_gr2_s2_2.csv   read_g_gr2_s2_3.csv
read_s_gr1_s2_1.csv    read_s_gr1_s2_2.csv   read_s_gr1_s2_3.csv
read_s_gr2_s2_1x.csv   read_s_gr2_s2_2.csv   read_s_gr2_s2_3.csv
```

### BigQuery — 14 objects in 4 datasets

| Dataset | Object | Rows | What it is |
|---|---|---:|---|
| `ff_00_raw` | `ext_read_s21` / `s22` / `s23` | — | external tables over GCS |
| | `raw_read_s21` | 596 | verbatim copy, 186 STRING columns |
| | `raw_read_s22` | 398 | verbatim copy, 291 STRING columns |
| | `raw_read_s23` | 398 | verbatim copy, 298 STRING columns |
| `ff_10_staging` | `stg_response_s21` | 11,920 | unpivoted section 2.1 |
| | `stg_response_s22` | 13,930 | unpivoted section 2.2 |
| | `stg_response_s23` | 14,328 | unpivoted section 2.3 |
| | **`stg_response`** | **40,178** | unioned, typed, cleaned |
| `ff_20_curated` | `dim_archetype` | 398 | one row per persona |
| | `dim_run` | 12 | one row per source file |
| | `dim_question` | 91 | one row per question |
| | `dim_question_option` | 334 | one row per answer option |
| `ff_30_marts` | — | — | empty until Phase 3 |

---

## 3. `raw_` vs `stg_` vs `dim_` — the layer model

The three prefixes are **three different jobs**, not three steps of one job.

```
12 CSVs ──► ff_00_raw ──► ff_10_staging ──► ff_20_curated ──► ff_30_marts
            evidence      workshop          contract          presentation
            immutable     rebuildable       what people use   Phase 3
```

### `sql/01_raw_*.sql` → `ff_00_raw` — the photocopy

**Job: prove what the source said.** Same shape as the CSV — wide, one row per
persona per file, 186 / 291 / 298 columns.

- **Every column is `STRING`.** Nothing cast, trimmed or cleaned.
- Why: autodetect would type `archetype_nps_score` as INT64 in some files and
  STRING in others, giving the three families incompatible schemas. And a cast
  that silently fails in raw is a cast nobody can ever audit.
- Adds only `_source_file` and `_loaded_at`. `_source_file` is where `run_id`
  comes from, which is why raw is built as external tables and materialised —
  `_FILE_NAME` exists only on external tables.
- **Nothing queries this layer except staging.** When a downstream number looks
  wrong, this is how you prove whether the source or the pipeline is at fault.

### `sql/10_*.sql`, `sql/11_*.sql` → `ff_10_staging` — the workshop

**Job: reshape and clean.** This is where the real work happens.

**(a) Wide becomes long.** One raw row of 291 columns becomes 35 rows.

```
BEFORE   archetype_id | Q1_question | Q1_meta | ... | Q35_qual    1 row  x 291 cols
AFTER    archetype_id | run_id | q_idx | meta | question_text
         | rating_value | selected_options | qual_text           35 rows x  15 cols
```

Why this is the entire point: `POSTINT` is `Q29` in section 2.2 but `Q7` in
section 2.3. Before the unpivot, querying it means knowing that. After it,
`WHERE meta = 'POSTINT'`.

**(b) Values get parsed and typed.**

| Raw string | Becomes |
|---|---|
| `1. 1. Increases my interest` | `option_position=1, option_code=1, option_label='Increases my interest'` |
| `2. 2. PC\|4. 4. Console` | an ARRAY of two option STRUCTs |
| `9. 99. None of the above` | `option_code=99` — the sentinel, **not** 9 |
| `''` | `NULL` |

Grain: **one row per (persona, run, question)** = 40,178.

### `sql/20_*.sql`–`23_*.sql` → `ff_20_curated` — the contract

**Job: name things once.** Dimensions are the **nouns** of the model: one row
per real-world thing, deduplicated, with derived attributes attached.

| Table | The noun | Derived columns |
|---|---|---|
| `dim_archetype` | a persona | `creative`, `cohort_code`, `gender_clean`, `age_band_banner`, `income_low/high_usd`, `nps_band`, `is_parent` |
| `dim_run` | a source file | `section_code`, `is_combined_file` |
| `dim_question` | a question | `question_key`, `question_kind` |
| `dim_question_option` | an answer option | `is_sentinel`, `scale_max` |

The value of a dimension is that a rule lives in **exactly one place**. The
`17-24` → `18-24` age decision is one CASE in one file, not repeated in every
banner query. Change it once and everything downstream follows.

### Still missing: the fact table

Dimensions are nouns; **facts are measurements**. `fct_response` (Step 12) is
one row per *answer*, joined to every dimension — the table analysts and models
actually query. That completes the star:

```
      dim_archetype          dim_question
              \                  /
               \                /
                --> fct_response <--  dim_question_option
                        |
                     dim_run
```

---

## 4. What each file in `tools/` does

Two kinds of file, and the split is deliberate.

### Generators — Python that writes SQL

| File | Writes | Why generated rather than hand-written |
|---|---|---|
| `gen_raw_schema.py` | `sql/01_raw_s2*.sql` (886 lines) | Emits 186/291/298 `col STRING` definitions **read from the real CSV header**. Hand-typing 298 names invites a typo you would discover four steps later; reading the header means a changed source file fails *here*, loudly. |
| `gen_unpivot.py` | `sql/10_stg_response_s2*.sql` (272 lines) | Emits the UNPIVOT `IN` list — 20/35/36 groups of 7 columns. Pure mechanical repetition, and it encodes the expected row count per family. |
| `gen_dim_archetype.py` | `sql/20_dim_archetype.sql` (232 lines) | Emits the 46-attribute projection inside each UNION arm (the F1 fix) plus the normalisation layer. |

Each generator **asserts before emitting**: all four headers in a family
byte-identical, column count equals 46 + 7N, no duplicate or BigQuery-invalid
column names.

### Runners — bash that executes and gates

| File | Runs | Gate |
|---|---|---|
| `slugify_upload.sh` | uploads the 12 CSVs | 12 objects, exact names |
| `land_raw.sh` | `sql/01_raw_*` | **Gate 1** — 596/398/398 = 1,392 |
| `shape_staging.sh` | `sql/10_*`, `sql/11_*` | 40,178 + 11 assertions |
| `build_curated_dims.sh` | `sql/20_*`–`23_*` | 398/12/91/334 + 35 assertions |

Every runner has the same shape: source `config.env` → substitute
`${PROJECT_ID}` / `${DS_*}` into a temp dir → **refuse to run if any
placeholder survives** → execute → assert → non-zero exit on failure.

**The assertion SQL follows the same route as the committed SQL.** Each runner
writes its gate block through a single-quoted heredoc (`<<'GATESQL'`) and passes
it through the same `resolve()` sed step, then reads it back with `$(cat …)`.

This is not cosmetic. A gate built as a double-quoted bash string lets bash
expand what it contains, and `set -u` then aborts the runner *after* the tables
have been rebuilt but *before* anything is checked — which is exactly what the
income band literal `'$75K-$125K'` did, bash reading it as positional parameter
`$7`. Command-substitution output is not re-expanded, so the heredoc route
delivers such literals to `bq` verbatim.

Two consequences worth knowing:

- `bash -n` **cannot** catch that class of fault. `$7` is valid syntax; `nounset`
  fires at run time.
- So the heredoc is written **before** the `--dry-run` exit, and `--dry-run`
  prints the resolved gate SQL. `./tools/<runner>.sh --dry-run` is therefore a
  real check on the assertion block, offline and without credentials. Run it
  after editing any gate.

### Why Python → SQL → bash rather than one script

- **The SQL is committed.** You review in VS Code exactly what ran against
  BigQuery, not a template you have to expand in your head.
- **Config never enters git.** Placeholders live in `sql/`, real values only in
  gitignored `config.env`.
- **Everything is re-runnable.** All statements are `CREATE OR REPLACE`; run any
  step twice and the counts are identical.

---

## 5. How to explain the pipeline

### One sentence

> We turned 12 wide survey exports into a queryable star schema in BigQuery,
> with every row count verified against the source files.

### Thirty seconds

> The study is 398 synthetic personas answering 91 questions, delivered as 12
> CSVs where each row is one persona and the questions are spread sideways
> across up to 298 columns. The same question sits at a different column
> position in different files, so nothing was queryable. We land the files in
> BigQuery unchanged, reshape them so one row equals one persona's answer to one
> question — 40,178 rows — and split out lookup tables for personas, questions,
> options and source files. Asking "what's the top box on purchase intent" is
> now a `WHERE` clause instead of knowing which column number it happens to
> occupy in which file.

### Two minutes, if pressed on rigour

1. **Four layers, each with one job.** Raw is an immutable all-STRING copy, so
   we can always prove what the source said. Staging reshapes and cleans.
   Curated is the contract analysts bind to. Marts is presentation. Nothing
   queries raw except staging — which is what will make adding the AUDIO and
   VIDEO modalities invisible to downstream consumers.

2. **Every gate number was computed from the source files in Python before any
   SQL was written** — 40,178 facts, 398 personas, 91 questions, 17,301
   verbatims. So a failing gate means a pipeline bug, never a wrong
   expectation. That is the whole value of doing it in this order.

3. **Section 2.1 was run twice** for cohorts G.2 and S.1 — same personas, same
   questions, different answers (ratings agree 60% of the time, verbatims 0%).
   These are not duplicates and nothing is deduplicated; they are modelled as
   replicate runs, which turns an export accident into a free answer-stability
   measurement for a synthetic panel. The consequence: **every query crossing
   sections needs `WHERE is_primary_run`**, or it double-counts 198 personas.

### If asked "did the original design just work?"

No — six defects, all caught by validating the design against the data before
building on it.

| | Defect | Impact if shipped |
|---|---|---|
| F1 | `dim_archetype` unions 291- and 298-column tables | query cannot compile |
| F2 | Imputed-age asserted at wrong grain (81 vs 22) | test fails on a *correct* build |
| F3 | Threshold off by 3 blank verbatims | same |
| F4 | Three contradictory filename conventions | `section_code` NULL on all 12 rows |
| **F5** | **Option prefix is `position. code.`, not a doubled code** | **sentinel 99 read as 9; BOT/B2B wrong on 3 questions** |
| **F6** | **Income has 8 shapes, regex anchored for 2** | **8 personas silently NULL in every income cut** |

F5 and F6 are the ones that mattered: both would have produced plausible,
wrong, *publishable* numbers rather than an error.

---

## 6. Step 12 — the remaining build

`sql/30_fct_response.sql` joins `stg_response` to `dim_archetype` and
`dim_question_option`, then resolves the replicate runs:

- `is_primary_run` — `ROW_NUMBER() OVER (PARTITION BY archetype_id,
  question_key ORDER BY ENDS_WITH(run_id,'x'), run_id)`. The standalone file
  wins over the combined 2.1X file. Deterministic, and a no-op for the 32,258
  single-run keys.
- `primary_code` (lowest non-sentinel code), `scale_max`, `n_runs_for_question`.
- `v_response_metrics` — a view adding `is_tb` / `is_t2b` / `is_bot` / `is_b2b`.
- `CLUSTER BY modality, creative, meta, cohort_code`. **No date partitioning:**
  40,178 rows is four orders of magnitude below where partitioning pays, and
  partitions of a few hundred rows would scan and cost *more*.

**Gate 4:** 40,178 rows / 398 personas / 91 questions / 36,218 distinct
`(persona, question)` keys / 36,218 primary rows / 7,920 replicate rows.
Identity: 32,258 + 7,920 = 40,178.

Then **Step 13** (DQ01–DQ16 with F2/F3-corrected thresholds) and **Step 14**,
where the deferred box-metric question returns: 9 of the 80 closed questions are
unordered multi-select pick-lists where top-box has no meaning, and
`fct_response_option` is named in the plan doc's architecture but defined
nowhere in it.
