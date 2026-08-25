# Phase 1 Runbook — Ingest, Clean & Sort

Companion to [`BIGQUERY_MIGRATION_PLAN.md`](../BIGQUERY_MIGRATION_PLAN.md). That
document is the *design*; this one is the *order of operations*, plus corrections
to four defects in it.

**Phase 1 is done** when `ff_20_curated.fct_response` holds exactly **40,178 rows**
and the DQ suite is green. No banners, no ML models — those are Phases 3 and 4.

**Pinned decisions**

| | |
|---|---|
| Region | `us-central1` (single region — BQML/Vertex must co-locate later) |
| Source | the 12 CSVs in `Written Descriptions_2026_08_7/` |
| Modality | READ only |
| Box metrics | implemented as designed; open question deferred to close-out |

---

## Verification status of the design

Every gate number in the plan doc was recomputed directly from the 12 source CSVs
before any code was written:

| Gate | Doc | Measured | |
|---|---:|---:|:--|
| `fct_response` rows | 40,178 | 40,178 | OK |
| Personas | 398 | 398 | OK |
| Questions | 91 | 91 | OK |
| `meta` codes | 36 | 36 | OK |
| `(persona, question)` keys | 36,218 | 36,218 | OK |
| Replicate keys / rows | 3,960 / 7,920 | 3,960 / 7,920 | OK |
| Verbatims | 17,301 | 17,301 | OK |
| Personas per cohort | 100/100/98/100 | 100/100/98/100 | OK |
| Persona attr conflicts across files | 0 | 0 | OK |

Consequence: **a failing gate is a pipeline bug, never a wrong expectation.**

---

## Corrections to the plan doc

### F1 — `dim_archetype` will not compile (§6.1)

It unions `raw_read_s22` and `raw_read_s23` via
`SELECT * EXCEPT(_source_file, _loaded_at)`. Those tables have **291 and 298
columns**; BigQuery rejects mismatched column counts.

**Fix:** project the 46 persona-attribute columns explicitly *inside each UNION
arm*. The existing `base` CTE already enumerates exactly those 46 — that
projection simply has to move above the union.

### F2 — `DQ07` asserts the wrong grain (§8)

The doc asserts 81 imputed-age rows. That 81 counts *row-occurrences across the 12
wide CSVs*, and each persona appears in 3–4 of them.

| Grain | True value |
|---|---:|
| `dim_archetype` (one row per persona) | **22** |
| `fct_response` | **2,302** |

**Fix:** split into `DQ07a = 22` (dim) and `DQ07b = 2,302` (fct). As written the
test fails against a correct build.

### F3 — `DQ08` threshold off by three (§8)

Asserts every type-1 (open-end) row carries `qual_text`, 0 violations. Measured:
4,574 type-1 rows, 4,571 verbatims — **3 are legitimately blank**.

**Fix:** pin at `= 3` as a known exception, so the test catches *drift* rather
than failing on day one.

### F4 — Filename convention contradicts itself three ways (§5.1 vs §6.2)

| Source | Produces / expects |
|---|---|
| §5.1 `sed` pipeline | `read_g_gr1_2_1x.csv` |
| §5.1 inline comment | `read_g_gr1_s22.csv` |
| §6.2 `dim_run` regex `r'(s2_\d)x?$'` | needs `...s2_1` |

Run as written, `REGEXP_EXTRACT` returns NULL and **`section_code` is NULL for all
12 rows**.

**Fix — convention pinned:**

```
read_{g|s}_{gr1|gr2}_s2_{1|2|3}[x].csv
```

The 12 resulting object names:

```
read_g_gr1_s2_1x   read_g_gr1_s2_2   read_g_gr1_s2_3
read_g_gr2_s2_1    read_g_gr2_s2_2   read_g_gr2_s2_3
read_s_gr1_s2_1    read_s_gr1_s2_2   read_s_gr1_s2_3
read_s_gr2_s2_1x   read_s_gr2_s2_2   read_s_gr2_s2_3
```

`dim_run`'s extractor becomes `r's(2_\d)x?$'` so `section_code` resolves to
`2.1` / `2.2` / `2.3` rather than `s2.1`.

**Get this right before uploading** — fixing it later means re-uploading.

### F5 — the doubled numeric prefix is `position. code.`, not a duplicated code

The doc's D2 describes values like `1. 1. Increases my interest` as a "doubled
option-code prefix" and strips both numbers, taking `option_code` from the
**first**. Measured across all 39,490 option tokens:

| Form | Count |
|---|---:|
| two prefixes, both numbers equal | 38,275 |
| one prefix | 1,215 |
| **two prefixes, numbers differ** | **419** |

They coincide 97% of the time, which is why this reads as duplication. But in
**every one** of the 419 disagreements the second number is `99`:

| Token | Count |
|---|---:|
| `9. 99. None of the above` | 411 |
| `6. 99. None of the above` | 5 |
| `17. 99. None of the above` | 3 |

So the first number is the option's **position in the displayed list** and the
second is its **coded value**. `99` is the D9 sentinel — and reading the first
number means the sentinel is never recognised as one:

| Question | `scale_max` reading first | correct |
|---|---:|---:|
| `Screener 1` | 9 | **8** |
| `PLATFORM` | 6 | **5** |
| `SOCIAL` | 17 | **15** |

On those three questions that inflates `scale_max`, so **BOT and B2B are wrong**
and the sentinel is averaged into `MEAN` as if it were a scale point.

**Fix:** `option_code` is the **last** numeric prefix, `option_position` the
first. RE2 has no backreferences, so it is done with a COALESCE of two patterns
rather than a repeated-group match:

```sql
SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64)        AS option_position,
SAFE_CAST(COALESCE(
  REGEXP_EXTRACT(opt, r'^\s*\d+\.\s*(\d+)\.'),   -- doubled: the real code
  REGEXP_EXTRACT(opt, r'^\s*(\d+)\.')            -- single:  the only number
) AS INT64)                                                    AS option_code,
```

Label stripping was never wrong — `^\s*\d+\.\s*(\d+\.\s*)?` is kept as-is.

**Regression guard:** the staging gate asserts `sentinel tokens >= 90` is
exactly **419**. If that returns 0, the code is being read from the position
prefix again.

Two related facts worth recording, both measured with the corrected code:

- Only **3 of 80** closed questions have a sentinel in their option universe.
- The 71 single-select ordinal questions have `scale_max` ∈ {1, 2, 3, 4, 6} —
  confirming there is genuinely **no 5-point scale anywhere** in the study.

### F6 — income has eight shapes, not two

D6 describes only points (`'$95,000 '`) and ranges (`'$65,000 - $75,000'`).
Measured over 398 personas there are **eight**:

| Shape | Personas |
|---|---:|
| `$N,N ` | 181 |
| `$N,N - $N,N` | 154 |
| `$N,N Household Income` | 33 |
| `$N,N (Household)` | 12 |
| **`Household Income: $N,N`** | **8** |
| `$N,N - $N,N+` | 7 |
| `$N,N+` | 2 |
| `$N,N (Household Income)` | 1 |

The doc's regex is anchored at `^\$`, so the 8 `Household Income: $N,N` personas
get **NULL income** — they would silently drop out of every income banner cut.

**Fix:** drop the anchor and take the first dollar amount anywhere in the
string. Verified to handle all eight shapes with zero DQ14 violations:

```sql
-- first amount anywhere, not anchored
SAFE_CAST(REPLACE(REGEXP_EXTRACT(archetype_income_range, r'\$([\d,]+)'), ',', '') AS INT64)
  AS income_low_usd,
-- second amount only exists in range forms
COALESCE(income_second_usd, income_first_usd) AS income_high_usd,
REGEXP_CONTAINS(archetype_income_range, r'\+') AS income_is_open_ended,
```

The `+` suffix (9 personas) is captured as `income_is_open_ended` rather than
being flattened to `low = high`, which would understate those households.

### A note on grain, since it caused F2 and recurs in D5

Several counts in the plan doc are **row-occurrences across the 12 wide files**,
not persona counts — each persona appears in 3–4 files. At `dim_archetype`
grain:

| Doc says | Actual (398 personas) |
|---|---|
| `MALE` case drift: 4 | **1** persona |
| Imputed `17-24`: 81 | **22** personas |
| Bare/hybrid ages: ~221 | **73** personas |

When a doc figure and a gate disagree, check the grain first.

### Deferred — box metrics on non-ordinal questions

Implemented as the doc specifies. Recorded here so it is not lost. Of the 80
closed questions:

- **71** are genuine ordinal scales, `scale_max` in {2, 3, 4, 6}. (There are **no
  5-point scales**; the doc's "don't hardcode 5-point" warning is right, but the
  real universe is 2/3/4/6.)
- **9** are unordered multi-select pick-lists — `CHARDES`, `STORYDES`, `SOCIAL`,
  `ELEMENT2`, `SEEWITH`, `PLATFORM`, `AUD2`, `GENREFIT`, `Screener 1` (all type 5),
  `scale_max` up to 20. Here `option_code` is a **category ID, not a rank**:
  `primary_code = MIN(option_code)` keeps only the lowest-numbered pick and
  discards the rest, and top/bottom-box carries no meaning — a "top box" on
  *"which social apps do you use"* is not a quantity.
- **2** are single-option formalities — `Screener 2` (country) and `INTRO2`
  (acknowledgement), `scale_max = 1`.

Also: **`fct_response_option` appears in the §4.1 architecture as part of "the
analysis contract" but has no DDL anywhere in the document** — per-option
incidence is exactly what those 9 questions need.

Nothing in Phase 1 *reads* these metrics, so no Phase 1 gate is affected. It
matters once banners are built on top. **Revisit at close-out (Step 14).**

---

## Steps

### 1 — Local prerequisites

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud --version && bq version
```

### 2 — `config.env` (repo root, gitignored)

```bash
export PROJECT_ID="your-project-id"
export REGION="us-central1"
export BUCKET="gs://your-project-id-arena-ff"
export GCS_PREFIX="${BUCKET}/arena-ff/read/v1"
export DS_RAW="ff_00_raw"
export DS_STG="ff_10_staging"
export DS_CUR="ff_20_curated"
export DS_MART="ff_30_marts"
```

Bucket names are globally unique — prefixing with the project ID is the reliable
trick. Bucket and datasets must share `us-central1`; external tables fail across
mismatched locations.

### 3 — Create GCP resources

```bash
source config.env
gcloud services enable bigquery.googleapis.com storage.googleapis.com
gcloud storage buckets create "$BUCKET" \
  --project="$PROJECT_ID" --location="$REGION" --uniform-bucket-level-access
for ds in "$DS_RAW" "$DS_STG" "$DS_CUR" "$DS_MART"; do
  bq --location="$REGION" mk -d "$PROJECT_ID:$ds"
done
bq ls --format=pretty      # expect 4 datasets
```

Four datasets because the rule that keeps this maintainable is **nothing queries
`00_raw` except `10_staging`**. Consumers bind to `20_curated` only, which is what
makes onboarding AUDIO/VIDEO later invisible downstream.

### 4 — Repo skeleton

```bash
mkdir -p tools sql
touch tools/{gen_raw_schema.py,gen_unpivot.py,validate_local.py,run_dq.py}
touch tools/slugify_upload.sh && chmod +x tools/slugify_upload.sh
```

### 5 — Upload the 12 CSVs — **checkpoint**

Uses the F4 convention above. Only the 12 `.csv` files migrate; the 2 stray
`.xlsx` in that folder are Excel renderings of CSVs already in the set.

```bash
gcloud storage ls "$GCS_PREFIX"     # GATE: exactly 12 objects
```

Source filenames contain em-dashes and spaces
(`3-ARENA-FF-G-gr1-2.2 — Results-c.csv`) — hostile to GCS URIs and to every glob
downstream, hence the rename.

### 6 — Gate 1: land the raw layer

`tools/gen_raw_schema.py` reads the **actual CSV header** and emits an all-STRING
schema (46 persona columns + 7 per question → 186 / 291 / 298). Reading the real
header means a source column change fails loudly at generation time instead of
silently misaligning the unpivot.

Everything lands as STRING deliberately: autodetect would type
`archetype_nps_score` as INT64 in some files and STRING in others, giving the three
section families incompatible schemas. Casting belongs in staging where the rules
are visible and testable.

Two flags are non-negotiable:

- `--allow_quoted_newlines` — 8,957 verbatim fields contain newlines; without it
  every file shreds into garbage rows.
- `--max_bad_records=0` — at this scale a rejected row is a bug, not noise.

```
GATE 1   raw_read_s21 = 596   raw_read_s22 = 398   raw_read_s23 = 398   total 1,392
```

### 7–14 — after Gate 1

| Step | What | Gate |
|---|---|---|
| 7 | Unpivot wide → long (`gen_unpivot.py`, 3 SQL files) | `stg_response` = 40,178 |
| 8 | Parse + type: strip `1. 1.` prefixes, split pipe-packed multi-selects | 0 labels retain a leading `N.` |
| 9 | `dim_archetype` — **F1** + age/gender/income normalisation | 398 rows, 0 null bands, 22 imputed |
| 10 | `dim_run` — **F4** | 12 rows, `SUM(n_rows)` = 1,392 |
| 11 | `dim_question`, `dim_question_option` | 91 questions / 36 metas |
| 12 | `fct_response`, `v_response_metrics` | **Gate 4:** 40,178 / 398 / 91 / 36,218 |
| 13 | DQ suite with corrected thresholds (**F2**, **F3**) | DQ01–DQ16 green |
| 14 | Close-out: clean rebuild + box-metric decision | all gates green from scratch |

---

## The one thing to keep in mind throughout

Section 2.1 was **run twice** for cohorts G.2 and S.1 — same personas, same 20
questions, *different answers* (`rating` agrees 60% of the time, `selected` 84%,
verbatims **0%**). These are **not duplicates** and nothing is deduplicated; they
are modelled as replicate runs, which turns an export accident into a free
answer-stability measurement for the synthetic panel.

**Every query that crosses sections needs `WHERE is_primary_run`**, or it
double-counts 198 personas.

---

## Independent cross-check

`tools/validate_local.py` recomputes Gates 1–4 and DQ01–DQ12 **from the CSVs in
pure Python, never touching BigQuery**. Two independent implementations agreeing on
40,178 / 398 / 91 / 36,218 is far stronger evidence than one pipeline agreeing with
itself.

---

## Open questions for the research lead

These block Phase 3+, not Phase 1 — landing and shaping are unaffected.

1. **G/S = Goyer/Sheridan?** Inferred from banner project IDs, never documented in
   the CSVs.
2. **Cohort `.1` vs `.2`?** The banner plans carry an `EXPOSURE ORDER` cut, but
   nothing in the CSVs encodes it — **that cut cannot currently be built.**
3. **998 vs 398** — is READ genuinely a subsample, or are CSVs missing?
4. **`17-24` band** — 22 personas default to `18-24`. Confirm, or supply exact ages.
5. **2.1 vs 2.1X** — are both runs methodologically valid, or is one a discarded
   pilot? Decides whether `is_primary_run` should prefer the standalone or the
   combined file.
