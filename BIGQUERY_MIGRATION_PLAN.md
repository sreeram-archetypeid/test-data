# ARENA Fatal Fury Concept Test — BigQuery Migration & Analysis Plan

**Project:** ARENA / Fatal Fury Concept Test (synthetic archetype panel)
**Scope of this document:** READ (Written Descriptions) modality — full migration + analysis.
**Status:** Execution-ready. Every number below was measured from the actual source files, not estimated.
**Last updated:** 2026-08-17

---

## 0. How to read this document

Sections 1–3 are **findings** — what the data actually is. Do not skip them; several
non-obvious properties of this dataset (replicate runs, doubled option codes, embedded
newlines) will silently corrupt the migration if you assume a normal survey export.

Sections 4–9 are the **build**, in execution order.
Section 10 is the **analysis layer**.
Sections 11–13 are **extensions** (AUDIO/VIDEO onboarding, human-panel calibration, ops).

A checkbox checklist is in Section 14.

---

## 1. Source inventory (measured)

### 1.1 Respondent-level data — Drive folder `1_C2IWyD87lzksluZEzOKpChpR6_zOM7L`

12 CSV files, ~19.5 MB total. Mirrored in this repo at `Written Descriptions_2026_08_7/`.

| File (stem) | Rows | Questions | Fact rows | Cohorts present |
|---|---:|---:|---:|---|
| `3-ARENA-FF-G-gr1-2.1X` | 200 | 20 | 4,000 | G.1 + G.2 |
| `3-ARENA-FF-G-gr1-2.2` | 100 | 35 | 3,500 | G.1 |
| `3-ARENA-FF-G-gr1-2.3` | 100 | 36 | 3,600 | G.1 |
| `3-ARENA-FF-G-gr2-2.1` | 100 | 20 | 2,000 | G.2 |
| `3-ARENA-FF-G-gr2-2.2` | 100 | 35 | 3,500 | G.2 |
| `3-ARENA-FF-G-gr2-2.3` | 100 | 36 | 3,600 | G.2 |
| `3-ARENA-FF-S-gr1-2.1` | 98 | 20 | 1,960 | S.1 |
| `3-ARENA-FF-S-gr1-2.2` | 98 | 35 | 3,430 | S.1 |
| `3-ARENA-FF-S-gr1-2.3` | 98 | 36 | 3,528 | S.1 |
| `3-ARENA-FF-S-gr2-2.1X` | 198 | 20 | 3,960 | S.1 + S.2 |
| `3-ARENA-FF-S-gr2-2.2` | 100 | 35 | 3,500 | S.2 |
| `3-ARENA-FF-S-gr2-2.3` | 100 | 36 | 3,600 | S.2 |
| **TOTAL** | **1,392** | — | **40,178** | **398 unique personas** |

**These are the reconciliation targets.** After the full pipeline runs, `fct_response`
must contain exactly **40,178** rows and `dim_archetype` exactly **398** rows. If either
number differs, stop and diagnose — do not proceed to analysis.

### 1.2 Manual analysis specs — Drive folder `1I6vqTbvUlRqFwqPdQn84yKrcqW2q435i`

Mirrored in this repo at `Support Files/`.

| File | Sheets | Purpose |
|---|---|---|
| `FF_READ_G_BannerPlan_2026-07-19.xlsx` | Banner 1 Total / 2 Demos / 3 Behaviors | **Primary spec for READ-Goyer.** 703 rows × 58 cols |
| `FF_READ_S_BannerPlan_2026-07-19.xlsx` | same | **Primary spec for READ-Sheridan** |
| `FF_AUDIO_G_BannerPlan_2026-07-19.xlsx` | same | Future modality (no respondent CSVs yet) |
| `FF_VIDEO_G_BannerPlan_2026-07-19.xlsx` | same | Future modality |
| `FF_VIDEO_S_BannerPlan_2026-07-19.xlsx` | same | Future modality |
| `FF_COMPARE6_BannerPlan_2026-07-19.xlsx` | Banner 1 Total | Cross-modality top-box comparison, 6 executions |
| `FATAL_FURY_CHART_REPORT_July_20_2026.pptx` | — | Reference output format |

> **Gap to note:** `FF_AUDIO_S_BannerPlan` is absent from the folder. If AUDIO-Sheridan
> is a real execution, that banner plan needs to be sourced before Section 11 runs.

### 1.3 Human benchmark — `Final W Tabs (1)/`

4 CSVs (Ban1/Ban2 × Freq/Pcnt), ~2,072 rows each. **Different universe:** N=800 *human*
respondents, banners `GENDER` and `QUADRANTS` (Men <35 / Men 35+ / Women <35 / …).
Used in Section 12 for synthetic-vs-human calibration. Not part of the main fact table.

### 1.4 Questionnaire

`ARENA_Fatal Fury Concept Test_Programming 061926.docx` — the canonical QRE. Authoritative
source for scale definitions and question wording when the CSV metadata is ambiguous.

---

## 2. What the data actually is

### 2.1 Design

Four **cohorts**, identified by `group_name` (which is always equal to `sample_name`):

| Cohort code | `group_name` | Creative | Personas |
|---|---|---|---:|
| G.1 | `3-ARENA-FF-G-test-26-8-7.1` | Goyer | 100 |
| G.2 | `3-ARENA-FF-G-test-26-8-7.2` | Goyer | 100 |
| S.1 | `3-ARENA-FF-S-test-26-8-7.1` | Sheridan | 98 |
| S.2 | `3-ARENA-FF-S-test-26-8-7.2` | Sheridan | 100 |

`G` / `S` map to the two script treatments (**Goyer** and **Sheridan**), confirmed by the
banner-plan project IDs (`FF_READ_G` / `FF_READ_S`) and by the `FF_COMPARE6` column headers
which read `Goyer | Sheridan` per modality.

`2.1` / `2.2` / `2.3` are **question blocks (sections)** of one questionnaire, not waves:
20, 35 and 36 questions respectively. The same `archetype_id` appears in all three sections
for its cohort, so **`archetype_id` is the join key across sections**.

### 2.2 The 2.1X replicate — read this carefully

The `…-2.1X` files are **combined** files that carry section 2.1 for *two* cohorts. Because
a standalone 2.1 file also exists for one of those cohorts, section 2.1 is **run twice for
two of the four cohorts**:

```
G-gr1-2.1X   contains G.1 (100) + G.2 (100)
G-gr2-2.1    contains G.2 (100)          -> G.2 has TWO runs of section 2.1; G.1 has ONE

S-gr2-2.1X   contains S.1 (98)  + S.2 (100)
S-gr1-2.1    contains S.1 (98)           -> S.1 has TWO runs of section 2.1; S.2 has ONE
```

The overlapping rows are **not duplicates**. Same personas, same 20 questions, *different
answers*:

| Field | Non-blank pairs compared | Identical |
|---|---:|---:|
| `rating` | 100 | 60.0% |
| `selected` | 1,600 | 84.1% |
| `qual` (verbatims) | 1,100 | **0.0%** |

Persona attribute columns are byte-identical across all files for a given `archetype_id`
(verified: zero mismatches across all 46 attribute columns).

**Decision (confirmed):** model these as **separate replicate runs**. Grain includes
`run_id`. Nothing is deduplicated. This is deliberate — it turns an accident of the export
into a free **answer-stability measurement** for the synthetic panel, which is exactly the
kind of QA evidence a synthetic methodology needs.

**Consequence for every analysis query:** section 2.1 is over-represented for G.2 and S.1.
Any `POSTINT`-style metric that crosses sections **must** pin a single run, e.g.
`WHERE is_primary_run` (defined in Section 7.3). Failing to do so double-counts 198 personas.

### 2.3 File layout

Every CSV is **wide**: 46 persona-attribute columns, then N repeating 7-column question
blocks (`Q{n}_question`, `Q{n}_meta`, `Q{n}_type`, `Q{n}_rating_label`, `Q{n}_rating`,
`Q{n}_selected`, `Q{n}_qual`). Total columns = 46 + 7N → 186 / 291 / 298.

**`Q{n}` numbering is positional within a file, not a stable question ID.** `Q1` in section
2.2 is a different question from `Q1` in section 2.3. The stable identity of a question is
**`(meta, question_text)`**.

### 2.4 Question inventory

**36 `meta` codes**, **91 distinct `(meta, question_text, type)` triples**. `meta` is a
question-group code; grid questions repeat it across items:

| meta | slots | distinct items | types | meta | slots | distinct items | types |
|---|---:|---:|---|---|---:|---:|---|
| `ACTIVITIES` | 24 | 6 | 2, 4 | `PLATFORM` | 4 | 1 | 5 |
| `AUD1` | 4 | 1 | 4 | `POLORIENT` | 4 | 1 | 4 |
| `AUD2` | 4 | 1 | 5 | `POSTINT` | 4 | 1 | 4 |
| `AUD3` | 4 | 1 | 4 | `PRELIKE1` | 4 | 1 | 1 |
| `CHARDES` | 4 | 1 | 5 | `PRELIKE2` | 4 | 1 | 1 |
| `DISLIKE` | 4 | 1 | 1 | `RECENTFILM1` | 4 | 1 | 1 |
| `ELEMENT1` | 60 | 4 | 4 | `RECONFIRM` | 4 | 1 | 4 |
| `ELEMENT2` | 4 | 1 | 5 | `SEEWITH` | 4 | 1 | 5 |
| `FRESHNSS` | 4 | 1 | 5 | `SOCIAL` | 4 | 1 | 5 |
| `GENREFIT` | 4 | 1 | 5 | `STORYDES` | 4 | 1 | 5 |
| `GFAN1` | 32 | 8 | 4 | `Screener 1` | 4 | 1 | 5 |
| `HIGHLIGHT` | 4 | 1 | 1 | `Screener 2` | 8 | 2 | 1, 4 |
| `IMPROVE` | 4 | 1 | 1 | `URG1` | 4 | 1 | 4 |
| `INTRO2` | 4 | 1 | 4 | `URG2` | 4 | 1 | 1 |
| `LIKE` | 4 | 1 | 1 | `VGFRAN1` | 44 | 11 | 4 |
| `PARENT1` | 4 | 1 | 4 | `VGFRAN2` | 40 | 1 | 4 |
| `PARENT2` | 4 | 1 | 1 | `VGFRAN3` | 40 | 1 | 4 |
| | | | | `VIABLE1` | 4 | 1 | 4 |
| | | | | `VIABLE2` | 4 | 1 | 4 |

### 2.5 `Q_type` semantics (derived from fill patterns)

| type | Meaning | `rating` | `selected` | `qual` |
|---|---|---:|---:|---:|
| `1` | Open-end / verbatim | 0 | 0 | 4,571 |
| `2` | Numeric rating (values 1–6) | 596 | 0 | 0 |
| `4` | Closed select (single or multi) | 0 | 30,830 | 10,738 |
| `5` | Select **+** mandatory follow-up verbatim | 0 | 4,178 | 1,992 |

Types 4 and 5 both carry `qual` — a "why did you pick that" probe. Total verbatims:
**17,301**, mean length 176 chars, max 604.

### 2.6 Scale convention

From the banner plans, row 6: *"qre PDF convention: **1 = best/top**"*. Option codes are
ascending-worst. Therefore:

- **Top Box (TB)** = `option_code = 1`
- **Top-2 Box (T2B)** = `option_code IN (1, 2)`
- **Bottom Box (BOT)** = `option_code = scale_max`
- **Bottom-2 Box (B2B)** = `option_code IN (scale_max - 1, scale_max)`
- **MEAN** = mean of `option_code` over valid codes

`scale_max` is **per question**, derived from the observed option universe — **excluding
codes ≥ 90** (`99. None of the above`, `98. Other`). Hardcoding a 5-point scale will produce
wrong BOT/B2B on the 4-point and 6-point items. See `dim_question_option` (Section 6.3).

---

## 3. Data-quality findings (all measured, all must be handled)

| # | Issue | Evidence | Handling |
|---|---|---|---|
| **D1** | **Embedded newlines in verbatims** | 8,957 fields contain `\n`. One 100-record file spans 501 physical lines. | `--allow_quoted_newlines` on load. **Mandatory** — without it every file shreds into garbage rows. |
| **D2** | **Prefix is `position. code. label`, not a doubled code** | 39,071 of 39,490 have position = code (so it *looks* doubled); **419 diverge** — e.g. `6. 99. None of the above` | Take the **second** number as `option_code`, falling back to the first. See D2 detail |
| **D3** | **Multi-select packed into one string** | Pipe-delimited: `2. 2. PC (Steam, GOG Galaxy)\|4. 4. Console (Xbox, Nintendo Switch)`. 9 metas, 2,663 cells, up to 7 options | `SPLIT(selected, '\|')` → `ARRAY<STRUCT<code, label>>`. **Multi-selects must not receive TB/T2B/MEAN.** See D3 detail |
| **D4** | **`archetype_age_range` is inconsistent** | 31 distinct values. Buckets (`30-34`), bare ages (`15`, `24`), and hybrids (`21 (17-24)`) all coexist | See D4 detail below |
| **D5** | **`archetype_gender` case drift** | `Male` (828), `Female` (560), `MALE` (4) | `INITCAP(TRIM(...))` |
| **D6** | **`archetype_income_range` mixed format** | Points with trailing space (`'$95,000 '`) *and* ranges (`'$65,000 - $75,000'`) | Parse to `income_low_usd` / `income_high_usd`; point ⇒ low = high |
| **D7** | **Curly apostrophes** | `Don’t really like…` (U+2019) | Preserve raw; normalise only in a derived `*_norm` grouping key |
| **D8** | **Filenames hostile to GCS** | Em-dash + spaces: `3-ARENA-FF-G-gr1-2.2 — Results-c.csv` | Rename to slugs on upload (Section 5.1) |
| **D9** | **Sentinel code 99 present** | 419 instances of code `99 None of the above` — `Screener 1` (411), `PLATFORM` (5), `SOCIAL` (3). No code `98` in the data. Only visible once D2 is parsed correctly | Exclude codes ≥ 90 from MEAN / BOT / B2B / `scale_max` |
| **D10** | **No BOM** | Verified across all 12 files | No action — noted so nobody "fixes" it |
| **D11** | **`archetype_nps_score` is a string** | Values `3`–`10`, no 0–2 present | `SAFE_CAST` to INT64; NPS band derived |

### D2 detail — the prefix is `position. code. label`

Almost every `selected` value carries two numeric prefixes:

```
1. 1. Increases my interest
↑  ↑  └── option label
│  └───── option code   (the punched value)
└──────── list position (where it appeared on screen)
```

It is tempting to read this as a duplicated code and grab the first number. **That is wrong**,
and it fails silently. In 39,071 of 39,490 option instances the two numbers happen to be equal,
which is why the doubling looks like an export artefact. In **419 instances they diverge** —
every one of them a "None of the above":

| meta | position | code | label | instances |
|---|---:|---:|---|---:|
| `Screener 1` | 9 | **99** | None of the above | 411 |
| `PLATFORM` | 6 | **99** | None of the above | 5 |
| `SOCIAL` | 17 | **99** | None of the above | 3 |

Reading the first number gives `option_code = 9`, `6`, `17` — three valid-looking scale
positions instead of a sentinel. Those 419 responses would then be swept into MEAN, into
`scale_max`, and (for `PLATFORM`, whose real scale max is 5) would push `scale_max` to 6 and
corrupt BOT/B2B for **every** `PLATFORM` response, not just the sentinel ones.

**Correct rule:** the option code is the **second** number when two are present, otherwise the
first.

```sql
COALESCE(
  SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*\d+\.\s*(\d+)\.') AS INT64),  -- 'pos. code. label'
  SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.')         AS INT64)   -- 'code. label'
) AS option_code
```

Keep the position too — it is the questionnaire's display order and is occasionally useful for
reproducing banner row order:

```sql
SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64) AS option_position
```

**Single-prefix values** (`code. label`, no position) total 1,635 and are concentrated in
`STORYDES`, which is single-prefix for **all** 1,195 of its values. The rest are scattered
stragglers (`ACTIVITIES` 5, `GFAN1` 8, `SOCIAL` 7, `PLATFORM` 5, `GENREFIT` 2, `PARENT1` 1) —
i.e. the export is *inconsistent within the same question*, so the parser must handle both
forms per-value rather than per-question. `Screener 1` is the clearest case: 189 doubled and
411 single-prefix values in the same column.

> **Over-stripping check:** a naive strip could eat real content if a label itself began with
> `<digits>.` (e.g. a label `1.5 hours` after a `1.` prefix). Verified across all 39,490
> instances: **zero** cases where stripping the prefix leaves a leading digit fragment. The
> regex is safe on this dataset — re-run the check when AUDIO/VIDEO land.

### D3 detail — multi-select packed into one string

**What the raw value looks like.** For "select all that apply" questions the export does not
create one column per option. It concatenates every chosen option into the single
`Q{n}_selected` cell, joined by a pipe, each with its own `position. code. label` prefix:

```
SOCIAL   →  2. 2. YouTube|4. 4. X (formerly Twitter)|8. 8. Reddit|13. 13. Discord
PLATFORM →  2. 2. PC (Steam, GOG Galaxy)|4. 4. Console (Xbox, Nintendo Switch)
STORYDES →  1. Action-packed|10. Great battle/fighting sequences|20. Feels authentic…
```

Left as-is, that string is useless analytically: `WHERE selected = '2. 2. YouTube'` misses
every respondent who picked YouTube *and* anything else, and there are 624 distinct raw
strings standing in for what is really ~130 options.

**Scale of it.** 35,008 non-empty `selected` cells → 39,490 option instances after splitting.
2,663 cells (**7.6%**) hold more than one option. Nine metas are multi-select:

| meta | max options chosen | distribution of options-per-cell |
|---|---:|---|
| `SOCIAL` | 7 | 1:22 · 2:122 · 3:113 · 4:89 · 5:42 · 6:9 · 7:1 |
| `CHARDES` | 6 | 2:70 · 3:280 · 4:41 · 5:4 · 6:3 |
| `STORYDES` | 5 | 1:1 · 2:62 · 3:281 · 4:43 · 5:11 |
| `GENREFIT` | 4 | 2:24 · 3:330 · 4:44 |
| `ELEMENT2` | 4 | 1:79 · 2:267 · 3:49 · 4:3 |
| `AUD2` | 4 | 1:14 · 2:306 · 3:75 · 4:3 |
| `SEEWITH` | 4 | 1:233 · 2:156 · 3:8 · 4:1 |
| `PLATFORM` | 3 | 1:176 · 2:211 · 3:11 |
| `Screener 1` | 2 | 1:592 · 2:4 |

The other 18 metas (`POSTINT`, `GFAN1`, `VGFRAN1/2/3`, `ACTIVITIES`, `URG1`, `VIABLE1/2`, …)
are always exactly one option. Note this is **not** the same split as `Q_type`: type 5 means
"select + verbatim follow-up", which is orthogonal to single-vs-multi. Derive
`is_multi_select` from the observed data (`MAX(ARRAY_LENGTH(selected_options)) > 1` per
`question_key`), not from `q_type`.

**Is splitting on `|` actually safe?** Yes, and this was verified rather than assumed. If any
option label contained a literal pipe, splitting would produce a fragment with no
`<digits>.` prefix. Across all **39,490** split parts, the number lacking a code prefix is
**0**. Additionally, no cell contains the same option code twice. The pipe is a clean
delimiter on this dataset.

**Target shape.** Explode into a repeated field so each chosen option is addressable:

```sql
ARRAY(
  SELECT AS STRUCT
    SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64) AS option_position,
    COALESCE(
      SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*\d+\.\s*(\d+)\.') AS INT64),
      SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.')         AS INT64)
    ) AS option_code,
    TRIM(REGEXP_REPLACE(opt, r'^\s*\d+\.\s*(\d+\.\s*)?', '')) AS option_label
  FROM UNNEST(SPLIT(COALESCE(selected, ''), '|')) AS opt
  WHERE TRIM(opt) != ''
) AS selected_options
```

Now "how many picked Discord" is `WHERE o.option_label = 'Discord'` after an `UNNEST`,
regardless of what else they picked.

**The consequence that matters most: multi-selects must not receive box metrics.**

Top-box, T2B, B2B, BOT and MEAN all assume a single ordered response on a ranked scale. A
multi-select has neither — `CHARDES` ("which words describe the character") has 19 unranked
options and a respondent picks 3. Averaging those codes produces a number with no meaning,
and `scale_max` is not a scale bound but just the length of a pick-list.

The banner plans already say this: 9 rows are annotated
`(multi-select: percentages can sum >100%)`. The correct metric is **per-option incidence** —
% of base selecting each option, summing to >100%.

This is why `dim_question_option` (§6.3) carries `is_multi_select`, why `scale_max` is `NULL`
for multi-selects, and why `v_response_metrics` (§7.3) returns `NULL` rather than `FALSE` for
`is_tb`/`is_t2b`/`is_bot`/`is_b2b` on those questions. `NULL` is deliberate — `COUNTIF` skips
nulls, so a multi-select silently contributes nothing to a top-box aggregate, whereas `FALSE`
would inflate the denominator and quietly understate every percentage.

Watch for the pick-list metas with large code ranges — `STORYDES` (20), `CHARDES` (19),
`SOCIAL` (15), `ELEMENT2` (14). Those are the ones a scale-oriented query would mangle worst.

### D4 detail — age normalisation

Observed value classes and target banner buckets (`13-17`, `18-24`, `25-34`, `35-44`, `45-54`, `55-64`):

| Source form | Examples | Count | Rule |
|---|---|---:|---|
| Clean bucket | `25-29`, `30-34`, `35-39`, `40-44`, `45-54`, `55-64` | 841 | Direct map |
| Sub-bucket | `13-16` | 54 | → `13-17` |
| Bare age | `13`,`14`,`15`,`16`,`18`…`24`,`38`,`40`,`42`,`43`,`44` | ~200 | Cast to INT, bucket it |
| Hybrid | `21 (17-24)` | 21 | Extract leading INT, bucket it |
| **Ambiguous** | **`17-24`** | **81** | **Straddles `13-17` and `18-24`** |

The 81 `17-24` rows carry no exact age and cannot be assigned deterministically.

**Rule adopted:** assign `17-24` → `18-24`, and set `age_band_is_imputed = TRUE`. Every
banner query gets a companion sensitivity check that reruns with those 81 rows excluded.
If the two runs disagree materially on any headline metric, escalate rather than publish.

Keep **all three** columns in `dim_archetype`: `age_raw` (untouched), `age_exact` (nullable
INT64), `age_band_banner` (the mapped bucket) — plus the imputed flag. Never overwrite `age_raw`.

---

## 4. Target architecture

### 4.1 Layers

```
GCS  gs://<bucket>/arena-ff/read/v1/*.csv
 │
 ▼  bq load (all columns STRING — no type inference)
00_raw      raw_read_s21, raw_read_s22, raw_read_s23      exact copy of source, immutable
 │
 ▼  UNPIVOT + parse
10_staging  stg_response, stg_archetype                   long grain, typed, cleaned
 │
 ▼  conform + dimensionalise
20_curated  dim_archetype, dim_question, dim_question_option,
            dim_run, fct_response, fct_response_option    ← the analysis contract
 │
 ▼
30_marts    mart_banner_read, mart_verbatim_coded,
            mart_driver_features, mart_calibration
```

Rule: **nothing queries `00_raw` except `10_staging`.** Analysts and models bind to
`20_curated` / `30_marts` only. This is what makes the AUDIO/VIDEO onboarding in Section 11
a no-op for downstream consumers.

### 4.2 Naming

- Datasets: `ff_00_raw`, `ff_10_staging`, `ff_20_curated`, `ff_30_marts`
- Location: **single region**, e.g. `us-central1`. Pick once and pin it — BQML and Vertex
  connections must live in the same region or model creation fails.
- All tables prefixed by layer role (`raw_`, `stg_`, `dim_`, `fct_`, `mart_`).

### 4.3 "Chunking" — how this data should actually be split

The word *chunking* covers three separate things here. They are handled differently, and
**one of them is a trap**.

**(a) Structural chunking — the real work.** Split each 186/291/298-column wide file into a
narrow **long** fact table plus a persona **dimension**. One source row of 291 columns
becomes 1 dimension row + 35 fact rows. This is what makes the data queryable: without it,
"what's the top-box on POSTINT" means knowing that POSTINT happens to be `Q29` in section
2.2 but `Q7` in section 2.3. After the unpivot it is `WHERE meta = 'POSTINT'`.

**(b) Load chunking — one file at a time, by section family.** The three section families
have different column counts, so they need three separate raw tables and three schemas.
Load file-by-file (12 loads), never with a wildcard across families. Each load stamps
`_source_file`, which is what `run_id` is derived from. Wildcard-loading all 12 at once
would both fail on schema mismatch and destroy run provenance.

**(c) Physical chunking — partitioning and clustering. Do not over-engineer this.**

> **Be honest about the scale.** The entire READ dataset is ~19.5 MB of CSV → roughly
> **40,178 fact rows**. That is *four orders of magnitude* below the point where BigQuery
> partitioning earns anything. A partitioned table here would create partitions of a few
> hundred rows each, and BigQuery's minimum billing granularity means you would likely
> **pay more and scan more**, not less.
>
> **Therefore: do not date-partition `fct_response`.** Use **clustering only.** Clustering
> is free, has no minimum-size penalty, and gives real block-pruning on the columns you
> actually filter by.

```sql
CLUSTER BY modality, creative, meta, cohort_code
```

Chosen in that order because it matches actual query shape: every banner query filters
modality + creative first, then question, then cut. Revisit **only** when AUDIO and VIDEO
land and the table crosses ~10M rows — at which point partition by `modality` via an
integer-range or ingestion-time scheme, not by date.

---

## 5. Ingestion

### 5.1 Stage to GCS with safe names

Source filenames contain em-dashes and spaces (D8). Rename on upload:

```bash
BUCKET=gs://<your-bucket>/arena-ff/read/v1
SRC="Written Descriptions_2026_08_7"

# 3-ARENA-FF-G-gr1-2.2 — Results-c.csv  ->  read_g_gr1_s22.csv
for f in "$SRC"/*.csv; do
  b=$(basename "$f" .csv)
  slug=$(echo "$b" \
    | sed -E 's/^3-ARENA-FF-//; s/ — Results-c$//; s/\./_/g; s/-/_/g; s/ +//g' \
    | tr 'A-Z' 'a-z')
  gsutil cp "$f" "$BUCKET/read_${slug}.csv"
done
gsutil ls "$BUCKET"   # expect 12 objects
```

> Only the 12 `.csv` files migrate. The two stray `.xlsx` files in that folder
> (`…-G-gr1-2.1X`, `…-G-gr1-2.2`) are Excel renderings of CSVs already in the set — skip them.

### 5.2 Load raw — every column STRING

Do **not** let BigQuery autodetect types. `archetype_income_range` would become a string
anyway, `archetype_nps_score` would become INT64 in some files and STRING in others, and the
three section families would get inconsistent schemas. Load everything as STRING and cast
in staging, where the rules are visible and testable.

```bash
DS=ff_00_raw
bq --location=us-central1 mk -d --description "ARENA FF raw landing (immutable)" $DS

load_section () {                        # $1=table  $2=glob  $3=n_questions
  local schema
  schema=$(python3 tools/gen_raw_schema.py "$3")     # emits col:STRING,... (46 + 7N)
  for obj in $(gsutil ls "$2"); do
    bq load \
      --source_format=CSV \
      --skip_leading_rows=1 \
      --allow_quoted_newlines \
      --allow_jagged_rows=false \
      --max_bad_records=0 \
      --encoding=UTF-8 \
      "$DS.$1" "$obj" "$schema"
  done
}

load_section raw_read_s21 "$BUCKET/*_2_1*.csv" 20    # 4 files → 596 rows
load_section raw_read_s22 "$BUCKET/*_2_2*.csv" 35    # 4 files → 398 rows
load_section raw_read_s23 "$BUCKET/*_2_3*.csv" 36    # 4 files → 398 rows
```

**`--allow_quoted_newlines` is not optional** (D1). **`--max_bad_records=0`** is deliberate:
this dataset is small enough that any rejected row is a bug, not noise. Fail loudly.

Add file provenance immediately after load — `_FILE_NAME` is only available on external
tables, so either (a) define the raw layer as external tables over GCS and materialise with
`_FILE_NAME`, or (b) load one file at a time into a temp table and `INSERT … SELECT` with a
literal. **Option (a) is recommended** — it is simpler and keeps raw genuinely immutable:

```sql
CREATE OR REPLACE EXTERNAL TABLE `ff_00_raw.ext_read_s22`
OPTIONS (
  format = 'CSV',
  uris = ['gs://<bucket>/arena-ff/read/v1/*_2_2*.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = true
);

CREATE OR REPLACE TABLE `ff_00_raw.raw_read_s22` AS
SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
FROM `ff_00_raw.ext_read_s22`;
```

**Gate 1:** `raw_read_s21` = 596 rows, `raw_read_s22` = 398, `raw_read_s23` = 398.
Total 1,392. Stop if not exact.

---

## 6. Curated model

### 6.1 `dim_archetype` — one row per persona (398)

Persona attributes are byte-identical across every file a persona appears in (verified), so
this is a clean `SELECT DISTINCT`. Keep all 46 raw attributes, and add derived columns.

```sql
CREATE OR REPLACE TABLE `ff_20_curated.dim_archetype`
CLUSTER BY creative, cohort_code AS
WITH unioned AS (
  SELECT * EXCEPT(_source_file, _loaded_at) FROM `ff_00_raw.raw_read_s22`
  UNION DISTINCT
  SELECT * EXCEPT(_source_file, _loaded_at) FROM `ff_00_raw.raw_read_s23`
),
base AS (
  SELECT DISTINCT
    archetype_id, group_name, sample_name,
    archetype_title, archetype_name, archetype_age_range, archetype_gender,
    archetype_race, archetype_marital_status, archetype_children_status,
    archetype_children, archetype_education_level, archetype_field_of_study,
    archetype_occupation, archetype_income_range, archetype_political_affiliation,
    archetype_religious_affiliation, archetype_location, archetype_location_type,
    archetype_hobbies_and_interests, archetype_lived_experience, archetype_nps_score,
    archetype_persona_summary, archetype_goals_and_motivations,
    archetype_audience_insights_triggers, archetype_psychographic_values,
    archetype_psychographic_interests, archetype_psychographic_lifestyle,
    archetype_purchasing_behaviors, archetype_challenges_pain_points,
    archetype_decision_making_steps, archetype_triggers_to_switch,
    archetype_product_expectations, archetype_product_influencers,
    archetype_media_channels, archetype_psychometric_vector_name,
    archetype_psychometric_vector_summary, archetype_psychometric_vector_characteristics,
    archetype_psychometric_vector_emotions, archetype_why_psychometric_vector_fits,
    archetype_group_dynamics, archetype_adoption_category_name,
    archetype_adoption_rationale, archetype_composite_attitude_score_summary,
    archetype_nps_summary, archetype_lived_experience_summary
  FROM unioned
)
SELECT
  b.*,
  'READ' AS modality,
  CASE WHEN REGEXP_CONTAINS(group_name, r'-G-') THEN 'Goyer'
       WHEN REGEXP_CONTAINS(group_name, r'-S-') THEN 'Sheridan' END AS creative,
  CONCAT(
    CASE WHEN REGEXP_CONTAINS(group_name, r'-G-') THEN 'G' ELSE 'S' END,
    '.', REGEXP_EXTRACT(group_name, r'\.(\d)$')
  ) AS cohort_code,

  -- D5 gender
  INITCAP(TRIM(archetype_gender)) AS gender_clean,

  -- D4 age
  archetype_age_range AS age_raw,
  SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})(?:\s|$|\s*\()') AS INT64) AS age_exact,
  CASE
    WHEN REGEXP_CONTAINS(archetype_age_range, r'^\d{1,2}(\s*\(|$)') THEN
      CASE
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 17 THEN '13-17'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 24 THEN '18-24'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 34 THEN '25-34'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 44 THEN '35-44'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 54 THEN '45-54'
        ELSE '55-64' END
    WHEN archetype_age_range = '13-16'  THEN '13-17'
    WHEN archetype_age_range = '17-24'  THEN '18-24'   -- imputed, see D4
    WHEN archetype_age_range IN ('25-29','30-34') THEN '25-34'
    WHEN archetype_age_range IN ('35-39','40-44') THEN '35-44'
    WHEN archetype_age_range = '45-54'  THEN '45-54'
    WHEN archetype_age_range = '55-64'  THEN '55-64'
  END AS age_band_banner,
  (archetype_age_range = '17-24') AS age_band_is_imputed,

  -- D6 income
  SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'^\$([\d,]+)'), ',', '') AS INT64)
    AS income_low_usd,
  COALESCE(
    SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'-\s*\$([\d,]+)'), ',', '') AS INT64),
    SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'^\$([\d,]+)'), ',', '') AS INT64)
  ) AS income_high_usd,

  -- D11 NPS
  SAFE_CAST(archetype_nps_score AS INT64) AS nps_score,
  CASE
    WHEN SAFE_CAST(archetype_nps_score AS INT64) >= 9 THEN 'Promoter'
    WHEN SAFE_CAST(archetype_nps_score AS INT64) >= 7 THEN 'Passive'
    ELSE 'Detractor' END AS nps_band,

  (archetype_children_status != 'no_children') AS is_parent
FROM base b;
```

**Gate 2:** `SELECT COUNT(*) = 398 AND COUNT(DISTINCT archetype_id) = 398`.
Also assert `COUNTIF(age_band_banner IS NULL) = 0` and `COUNTIF(creative IS NULL) = 0`.

### 6.2 `dim_run` — makes the 2.1X replicate explicit

`dim_run` is a thin lookup: `run_id → section_code, source_file, is_combined_file`. It does
**not** carry the primary-run flag — that depends on the persona (G.1 and G.2 sit in the same
file but only one of them is replicated), so it can only be resolved at the fact grain. See
Section 7.3 for the authoritative definition.

```sql
CREATE OR REPLACE TABLE `ff_20_curated.dim_run` AS
SELECT
  run_id,
  source_file,
  -- run_id looks like 'read_g_gr1_s2_2' / 'read_s_gr2_s2_1x'
  REPLACE(REGEXP_EXTRACT(run_id, r'(s2_\d)x?$'), '_', '.')   AS section_code,
  ENDS_WITH(run_id, 'x')                                     AS is_combined_file,
  CASE WHEN REGEXP_CONTAINS(run_id, r'_g_') THEN 'Goyer'
       ELSE 'Sheridan' END                                   AS creative_of_file,
  n_rows
FROM (
  SELECT
    LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$')) AS run_id,
    ANY_VALUE(_source_file)                               AS source_file,
    COUNT(*)                                              AS n_rows
  FROM (
    SELECT _source_file FROM `ff_00_raw.raw_read_s21`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s22`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s23`
  )
  GROUP BY run_id
);
```

**Gate 2b:** `dim_run` = **12** rows, and `SUM(n_rows)` = **1,392**.

> Note `creative_of_file` is a property of the *file*, not of every row in it — the combined
> `2.1X` files contain two cohorts, though both share a creative. Always take `creative` from
> `dim_archetype`, never from the filename.

### 6.3 `dim_question` and `dim_question_option`

```sql
-- 91 rows: the stable question identity
CREATE OR REPLACE TABLE `ff_20_curated.dim_question` AS
SELECT
  TO_HEX(MD5(CONCAT(meta, '||', question_text))) AS question_key,
  meta, question_text, q_type,
  CASE q_type
    WHEN '1' THEN 'open_end'
    WHEN '2' THEN 'numeric_rating'
    WHEN '4' THEN 'closed_select'
    WHEN '5' THEN 'select_plus_verbatim'
  END AS question_kind
FROM (SELECT DISTINCT meta, question_text, q_type FROM `ff_10_staging.stg_response`);

-- option universe, multi-select flag, and scale_max (single-select only, sentinels excluded)
CREATE OR REPLACE TABLE `ff_20_curated.dim_question_option` AS
WITH multi AS (          -- D3: derive from data, NOT from q_type
  SELECT question_key,
         MAX(ARRAY_LENGTH(selected_options)) > 1 AS is_multi_select
  FROM `ff_10_staging.stg_response`
  GROUP BY question_key
),
opts AS (
  SELECT DISTINCT r.question_key, o.option_code, o.option_position, o.option_label
  FROM `ff_10_staging.stg_response` r, UNNEST(r.selected_options) o
  WHERE o.option_code IS NOT NULL
)
SELECT
  o.question_key, o.option_code, o.option_position, o.option_label,
  o.option_code >= 90 AS is_sentinel,
  m.is_multi_select,
  -- scale_max is meaningless for a pick-list; leave it NULL so box metrics can't be computed
  IF(m.is_multi_select, NULL,
     MAX(IF(o.option_code >= 90, NULL, o.option_code))
       OVER (PARTITION BY o.question_key)) AS scale_max
FROM opts o
JOIN multi m USING (question_key);
```

**Gate 3:** `dim_question` = **91** rows, **36** distinct `meta`.
`dim_question_option` must show **9** multi-select metas (`SOCIAL`, `CHARDES`, `STORYDES`,
`GENREFIT`, `ELEMENT2`, `AUD2`, `SEEWITH`, `PLATFORM`, `Screener 1`) and **419** sentinel
instances at code 99.

---

## 7. The unpivot — wide to long

### 7.1 Pattern

BigQuery's multi-column `UNPIVOT` handles this natively. One statement per section family
(they differ only in how many groups are listed).

```sql
CREATE OR REPLACE TABLE `ff_10_staging.stg_response_s22` AS
SELECT
  archetype_id,
  LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$')) AS run_id,
  q_idx, question_text, meta, q_type, rating_label, rating, selected, qual
FROM `ff_00_raw.raw_read_s22`
UNPIVOT (
  (question_text, meta, q_type, rating_label, rating, selected, qual)
  FOR q_idx IN (
    (Q1_question,  Q1_meta,  Q1_type,  Q1_rating_label,  Q1_rating,  Q1_selected,  Q1_qual)  AS 1,
    (Q2_question,  Q2_meta,  Q2_type,  Q2_rating_label,  Q2_rating,  Q2_selected,  Q2_qual)  AS 2,
    -- … through 35 …
    (Q35_question, Q35_meta, Q35_type, Q35_rating_label, Q35_rating, Q35_selected, Q35_qual) AS 35
  )
);
```

Generate the `IN` list rather than typing it — 20 + 35 + 36 = 91 lines:

```python
# tools/gen_unpivot.py <n>
import sys
n = int(sys.argv[1])
f = "    (Q{i}_question, Q{i}_meta, Q{i}_type, Q{i}_rating_label, Q{i}_rating, Q{i}_selected, Q{i}_qual) AS {i}"
print(",\n".join(f.format(i=i) for i in range(1, n + 1)))
```

> **Why `UNPIVOT` and not a JSON trick:** `JSON_VALUE` requires a literal path, so you cannot
> loop `'$.Q' || i || '_question'`. `UNPIVOT` is the only clean native option.

### 7.2 Parse and type

```sql
CREATE OR REPLACE TABLE `ff_10_staging.stg_response` AS
WITH all_sections AS (
  SELECT *, '2.1' AS section_code FROM `ff_10_staging.stg_response_s21`
  UNION ALL SELECT *, '2.2' FROM `ff_10_staging.stg_response_s22`
  UNION ALL SELECT *, '2.3' FROM `ff_10_staging.stg_response_s23`
)
SELECT
  archetype_id, run_id, section_code, q_idx,
  meta, question_text, q_type,
  TO_HEX(MD5(CONCAT(meta, '||', question_text))) AS question_key,

  rating_label,
  SAFE_CAST(NULLIF(TRIM(rating), '') AS INT64) AS rating_value,

  NULLIF(selected, '') AS selected_raw,
  -- D3: split on '|'  +  D2: prefix is 'position. code. label' (code = 2nd number if present)
  ARRAY(
    SELECT AS STRUCT
      SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64) AS option_position,
      COALESCE(
        SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*\d+\.\s*(\d+)\.') AS INT64),
        SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.')         AS INT64)
      ) AS option_code,
      TRIM(REGEXP_REPLACE(opt, r'^\s*\d+\.\s*(\d+\.\s*)?', '')) AS option_label
    FROM UNNEST(SPLIT(COALESCE(selected, ''), '|')) AS opt
    WHERE TRIM(opt) != ''
  ) AS selected_options,

  NULLIF(qual, '')                            AS qual_text,
  CHAR_LENGTH(COALESCE(qual, ''))             AS qual_len,
  -- D7: normalised copy for grouping only; qual_text stays verbatim
  NULLIF(REPLACE(REPLACE(qual, '’', "'"), '“', '"'), '') AS qual_text_norm
FROM all_sections
WHERE question_text IS NOT NULL AND question_text != '';
```

### 7.3 `fct_response` — the analysis contract

```sql
CREATE OR REPLACE TABLE `ff_20_curated.fct_response`
CLUSTER BY modality, creative, meta, cohort_code AS
WITH joined AS (
  SELECT
    s.*, a.creative, a.cohort_code, a.modality,
    -- primary-run flag: where a persona has 2 runs of a section, the standalone
    -- (non-combined) file wins. Deterministic, and a no-op for single-run personas.
    ROW_NUMBER() OVER (
      PARTITION BY s.archetype_id, s.question_key
      ORDER BY ENDS_WITH(s.run_id, 'x') ASC, s.run_id ASC
    ) AS run_rank,
    COUNT(*) OVER (PARTITION BY s.archetype_id, s.question_key) AS run_count
  FROM `ff_10_staging.stg_response` s
  JOIN `ff_20_curated.dim_archetype` a USING (archetype_id)
)
SELECT
  j.* EXCEPT(run_rank, run_count),
  (run_rank = 1) AS is_primary_run,
  run_count      AS n_runs_for_question,
  -- box metrics, sentinel-aware
  (SELECT MIN(o.option_code) FROM UNNEST(j.selected_options) o WHERE o.option_code < 90) AS primary_code,
  d.scale_max
FROM joined j
LEFT JOIN (SELECT DISTINCT question_key, scale_max FROM `ff_20_curated.dim_question_option`) d
  USING (question_key);
```

Then the reusable metric view every banner and model binds to:

```sql
CREATE OR REPLACE VIEW `ff_20_curated.v_response_metrics` AS
SELECT *,
  primary_code = 1                                    AS is_tb,
  primary_code IN (1, 2)                              AS is_t2b,
  primary_code = scale_max                            AS is_bot,
  primary_code IN (scale_max - 1, scale_max)          AS is_b2b
FROM `ff_20_curated.fct_response`;
```

**Gate 4 — the big one:**

```sql
SELECT
  COUNT(*)                                        AS rows_total,        -- expect 40,178
  COUNT(DISTINCT archetype_id)                    AS personas,          -- expect 398
  COUNT(DISTINCT question_key)                    AS questions,         -- expect 91
  COUNT(DISTINCT FORMAT('%s|%s', archetype_id, question_key))
                                                  AS distinct_keys,     -- expect 36,218
  COUNTIF(is_primary_run)                         AS primary_rows,      -- expect 36,218
  COUNTIF(n_runs_for_question = 2)                AS replicate_rows     -- expect  7,920
FROM `ff_20_curated.fct_response`;
```

All five expected values were computed directly from the source files and are exact:

| Quantity | Value | Derivation |
|---|---:|---|
| Fact rows | 40,178 | Σ (rows × questions) over the 12 files |
| Distinct `(persona, question)` keys | 36,218 | = `primary_rows` |
| Keys with 2 runs | 3,960 | G.2 (100 × 20) + S.1 (98 × 20) = 2,000 + 1,960 |
| Rows belonging to a replicated key | 7,920 | 3,960 × 2 |
| Keys with 1 run | 32,258 | 36,218 − 3,960 |

Sanity identity: `32,258 + 7,920 = 40,178`. Any deviation is a blocker, not a rounding issue.

---

## 8. Data-quality test suite

Materialise as assertion queries in `ff_30_marts.dq_results`, run after every rebuild.
Every one of these encodes a defect actually found in the data — they are regression tests,
not hypotheticals.

| ID | Assertion | Threshold |
|---|---|---|
| `DQ01` | `fct_response` row count | `= 40,178` |
| `DQ02` | Distinct personas | `= 398` |
| `DQ03` | Distinct `question_key` | `= 91` |
| `DQ04` | Personas per cohort | G.1=100, G.2=100, S.1=98, S.2=100 |
| `DQ05` | No orphan facts | `fct` ⟕ `dim_archetype` yields 0 nulls |
| `DQ06` | `age_band_banner` never null | `= 0` |
| `DQ07` | Imputed age rows | `= 81` (drift alarm) |
| `DQ08` | Every type-1 row has `qual_text` | `= 0` violations |
| `DQ09` | Every type-4/5 row has ≥1 `selected_options` | `= 0` violations |
| `DQ10` | `option_label` never retains a leading `\d+\.` | `= 0` (catches D2 regressions) |
| `DQ11` | `scale_max` between 2 and 12 for all closed questions | `= 0` violations |
| `DQ12` | Verbatim count | `= 17,301` |
| `DQ13` | Exactly one `is_primary_run` per (persona, question) | `= 0` violations |
| `DQ14` | `income_high_usd >= income_low_usd` | `= 0` violations |
| `DQ15` | Replicated keys (`n_runs_for_question = 2`) | `= 3,960` keys / `7,920` rows |
| `DQ16` | `dim_run` completeness | `= 12` rows, `SUM(n_rows) = 1,392` |

---

## 9. Reproducing the banner tables

The banner plans define **7 banner groups** across 3 sheets:

| Sheet | Banner groups |
|---|---|
| Banner 1 Total | GENDER: MALES · GENDER: FEMALES · RACE/ETHNICITY · PERSONAL INCOME · RELATIONSHIP STATUS · MOVIE GENRE FANS TOP BOX · MEDIA BEHAVIORS TOP BOX · VIDEO GAME TITLE APPEAL TOP BOX · EXPOSURE ORDER |
| Banner 2 Demos | the demographic subset |
| Banner 3 Behaviors | the behavioural subset |

Two distinct cut families, and they resolve differently:

- **Demographic cuts** come from `dim_archetype` (`gender_clean`, `age_band_banner`,
  `archetype_race`, `income_*`, `archetype_marital_status`, `is_parent`).
- **Behavioural cuts** come from *responses* — top-box on `ACTIVITIES`, `GFAN1`, `VGFRAN1`,
  `POSTINT`. These must be built as a persona-level flag table first, then joined back:

```sql
CREATE OR REPLACE TABLE `ff_30_marts.dim_archetype_cuts` AS
SELECT
  archetype_id,
  LOGICAL_OR(meta = 'GFAN1'     AND question_text LIKE '%Martial Arts%' AND is_tb) AS cut_fan_martial_arts,
  LOGICAL_OR(meta = 'GFAN1'     AND question_text LIKE '%Action%'       AND is_tb) AS cut_fan_action,
  LOGICAL_OR(meta = 'VGFRAN1'   AND question_text LIKE '%Fatal Fury%'   AND is_tb) AS cut_know_fatal_fury,
  LOGICAL_OR(meta = 'ACTIVITIES'AND question_text LIKE '%video games%'  AND is_tb) AS cut_heavy_gamer,
  LOGICAL_OR(meta = 'POSTINT'                                           AND is_tb) AS cut_postint_tb
FROM `ff_20_curated.v_response_metrics`
WHERE is_primary_run              -- REQUIRED: see 2.2
GROUP BY archetype_id;
```

Then the banner generator — one long/tidy table, pivoted at presentation time:

```sql
CREATE OR REPLACE TABLE `ff_30_marts.mart_banner_read` AS
SELECT
  m.creative, m.meta, m.question_text, m.question_key,
  cut.cut_name, cut.cut_value,
  COUNT(*)                                             AS n,
  SAFE_DIVIDE(COUNTIF(m.is_tb),  COUNT(*))             AS tb_pct,
  SAFE_DIVIDE(COUNTIF(m.is_t2b), COUNT(*))             AS t2b_pct,
  SAFE_DIVIDE(COUNTIF(m.is_b2b), COUNT(*))             AS b2b_pct,
  SAFE_DIVIDE(COUNTIF(m.is_bot), COUNT(*))             AS bot_pct,
  AVG(IF(m.primary_code < 90, m.primary_code, NULL))   AS mean_score
FROM `ff_20_curated.v_response_metrics` m
JOIN `ff_20_curated.dim_archetype` a USING (archetype_id)
CROSS JOIN UNNEST([
  STRUCT('TOTAL'   AS cut_name, 'Total'                AS cut_value),
  STRUCT('GENDER',            a.gender_clean),
  STRUCT('AGE',               a.age_band_banner),
  STRUCT('RACE',              a.archetype_race),
  STRUCT('RELATIONSHIP',      a.archetype_marital_status),
  STRUCT('PARENT',            IF(a.is_parent, 'Parent', 'Non-parent'))
]) AS cut
WHERE m.is_primary_run
GROUP BY 1,2,3,4,5,6;
```

Add significance testing (the banner plans imply stat-testing between cuts) with a two-proportion
z-test in SQL, or in **BigQuery DataFrames** where it reads far more naturally.

> **Verbatim rows:** the banner plans mark 8 rows as `OE — verbatims not tabulated here`.
> Those are exactly the type-1 questions, and Section 10 is where they finally get tabulated —
> which is the main thing BigQuery buys you over the manual Excel process.

---

## 10. Analysis layer

### 10.1 Recommended headline analysis

> **Concept Interest Driver Analysis — what actually moves `POSTINT` top-box, and does it
> differ between the Goyer and Sheridan scripts?**

This is the right call for four reasons:

1. `POSTINT` ("how interested would you be in seeing this movie in a theater") is the
   commercial decision variable, and `FF_COMPARE6` already treats its top-box as *the*
   headline number across all six executions.
2. It is the one analysis that consumes **every** part of the dataset at once — 46 persona
   attributes, 91 questions, and 17,301 verbatims.
3. The manual banner process **cannot** do it. Crosstabs show *association* one cut at a
   time; they cannot rank drivers while holding other factors constant. This is the specific
   gap BigQuery closes.
4. G-vs-S is a genuine controlled comparison — same questionnaire, same persona
   construction, different creative. That is a clean experimental contrast.

### 10.2 Three models

#### Model 1 — `LOGISTIC_REG`: the driver ranking (build this first)

Outcome: `POSTINT` top-box. Features: demographics, genre fandom, franchise familiarity,
platform behaviour, psychometric vector, adoption category, NPS band.

```sql
CREATE OR REPLACE MODEL `ff_30_marts.m_postint_drivers`
OPTIONS (
  model_type = 'LOGISTIC_REG',
  input_label_cols = ['postint_tb'],
  auto_class_weights = TRUE,
  l2_reg = 0.1,
  data_split_method = 'AUTO_SPLIT',
  enable_global_explain = TRUE      -- required for ML.GLOBAL_EXPLAIN
) AS
SELECT
  f.postint_tb,
  a.creative, a.gender_clean, a.age_band_banner, a.archetype_race,
  a.income_low_usd, a.is_parent, a.nps_band,
  a.archetype_psychometric_vector_name, a.archetype_adoption_category_name,
  a.archetype_location_type,
  c.cut_fan_martial_arts, c.cut_fan_action, c.cut_know_fatal_fury, c.cut_heavy_gamer
FROM (
  SELECT archetype_id, LOGICAL_OR(is_tb) AS postint_tb
  FROM `ff_20_curated.v_response_metrics`
  WHERE meta = 'POSTINT' AND is_primary_run
  GROUP BY archetype_id
) f
JOIN `ff_20_curated.dim_archetype`    a USING (archetype_id)
JOIN `ff_30_marts.dim_archetype_cuts` c USING (archetype_id);

SELECT * FROM ML.GLOBAL_EXPLAIN(MODEL `ff_30_marts.m_postint_drivers`)
ORDER BY attribution DESC;

SELECT * FROM ML.EVALUATE(MODEL `ff_30_marts.m_postint_drivers`);
```

> **Honest caveat on N.** 398 personas is a small training set. Read this model as a
> *driver-ranking and hypothesis-generating* tool, not a predictive one. Report
> `ML.GLOBAL_EXPLAIN` attributions and coefficient signs; treat ROC-AUC as a sanity check
> (below ~0.65 means the features are not separating and the ranking is not trustworthy).
> Do not over-fit by adding all 91 questions as features — keep it to the ~15 above.
> This constraint disappears the moment AUDIO and VIDEO land and N approaches 998.

#### Model 2 — `KMEANS`: data-driven segmentation

The dataset ships a *hand-authored* segmentation (`archetype_psychometric_vector_name`).
Cluster independently on behaviour and check whether the authored vectors reproduce — a
direct validity test of the persona construction.

```sql
CREATE OR REPLACE MODEL `ff_30_marts.m_persona_segments`
OPTIONS (
  model_type = 'KMEANS',
  num_clusters = HPARAM_RANGE(3, 8),      -- let BQML pick by Davies-Bouldin
  standardize_features = TRUE,
  kmeans_init_method = 'KMEANS++'
) AS
SELECT * EXCEPT(archetype_id)
FROM `ff_30_marts.mart_driver_features`;

-- do the authored vectors line up with the discovered clusters?
SELECT
  a.archetype_psychometric_vector_name,
  p.CENTROID_ID,
  COUNT(*) AS n
FROM ML.PREDICT(MODEL `ff_30_marts.m_persona_segments`,
                TABLE `ff_30_marts.mart_driver_features`) p
JOIN `ff_20_curated.dim_archetype` a USING (archetype_id)
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
```

A near-diagonal crosstab means the authored personas are behaviourally coherent. A scrambled
one is a **finding worth reporting** — it says the psychometric labels are not showing up in
the answers.

#### Model 3 — `AI.GENERATE_TABLE`: structured coding of 17,301 verbatims

**The highest-value item in this plan.** The banner plans explicitly leave open-ends
untabulated (`OE — verbatims not tabulated here`). There are 17,301 of them at ~176 chars
each, across `LIKE`, `DISLIKE`, `IMPROVE`, `HIGHLIGHT`, `PRELIKE1/2`, `URG2`, `PARENT2`,
`RECENTFILM1` plus the type-4/5 follow-up probes. Hand-coding that is weeks of work; here
it is one query.

*Prerequisite:* a Vertex AI external connection in the **same region** as the datasets, with
`roles/aiplatform.user` granted to the connection's service account.

```sql
CREATE OR REPLACE TABLE `ff_30_marts.mart_verbatim_coded` AS
SELECT
  archetype_id, question_key, meta, creative, cohort_code, qual_text,
  sentiment, primary_theme, secondary_theme, mentions_martial_arts, is_actionable
FROM AI.GENERATE_TABLE(
  MODEL `ff_30_marts.gemini_endpoint`,
  (
    SELECT
      archetype_id, question_key, meta, creative, cohort_code, qual_text,
      CONCAT(
        'You are coding open-ended responses from a movie concept test. ',
        'Question: ', question_text, '\n',
        'Response: ', qual_text
      ) AS prompt
    FROM `ff_20_curated.v_response_metrics`
    WHERE qual_text IS NOT NULL AND is_primary_run
  ),
  STRUCT(
    'sentiment STRING, primary_theme STRING, secondary_theme STRING, mentions_martial_arts BOOL, is_actionable BOOL'
      AS output_schema,
    0.0 AS temperature      -- determinism matters for coded data
  )
);
```

Then feed the codes **back** into Model 1 as features. That closes the loop: qualitative
signal becomes a quantitative driver. It is the thing the manual Excel process structurally
cannot do.

Operational notes: run in batches by `meta`; pin `temperature = 0.0`; hand-audit a 100-row
sample against human coding before trusting the output; version the prompt in git, because
a prompt change silently changes every code.

#### Optional Model 4 — `BOOSTED_TREE_CLASSIFIER`

Same features and label as Model 1. If it materially outperforms the logistic model on AUC,
there are interaction effects (e.g. *martial-arts fan* **×** *knows Fatal Fury*) that the
linear model is missing. Use `ML.FEATURE_IMPORTANCE` to find them, then add explicit
interaction terms back into Model 1 for interpretability. Given N=398, expect mild gains at
best — this is a diagnostic, not a replacement.

### 10.3 Answer-stability analysis (free, thanks to the 2.1X decision)

Because replicates were preserved rather than deduplicated:

```sql
SELECT
  meta, question_text,
  COUNT(*)                                                     AS n_pairs,
  AVG(CAST(a.primary_code = b.primary_code AS INT64))          AS agreement_rate
FROM `ff_20_curated.fct_response` a
JOIN `ff_20_curated.fct_response` b
  USING (archetype_id, question_key)
WHERE a.run_id < b.run_id
GROUP BY 1, 2
ORDER BY agreement_rate ASC;
```

Low-agreement questions are ones where the synthetic personas are unstable — a caveat that
belongs on any slide quoting those metrics. Baselines already measured: ratings 60%,
selects 84%, verbatims 0%.

---

## 11. Onboarding AUDIO and VIDEO later

The schema is modality-aware from day one, so this is additive — **no migration, no
backfill, no downstream changes.**

1. **Land the CSVs** at `gs://<bucket>/arena-ff/audio/v1/` and `…/video/v1/`.
2. **Confirm the shape matches.** Before anything else, re-run the profiler on one file:
   46 attribute columns, 7-column question blocks, `archetype_id` present, section split
   20/35/36. If AUDIO/VIDEO were fielded with a different questionnaire, the `dim_question`
   universe grows beyond 91 — that is fine and expected, but the DQ thresholds in Section 8
   must be re-baselined rather than "fixed".
3. **Load to `ff_00_raw.raw_audio_s2x` / `raw_video_s2x`** using the identical
   `load_section` function. Same flags. `--allow_quoted_newlines` still mandatory.
4. **Set `modality`** to `'AUDIO'` / `'VIDEO'` in the `dim_archetype` and `fct_response`
   builds — change the literal `'READ'` in Section 6.1 to a parameter.
5. **`UNION ALL` into the same curated tables.** Clustering already leads with `modality`,
   so existing READ queries prune the new data automatically and stay the same cost.
6. **Watch for cross-modality persona reuse.** If the same `archetype_id` appears in READ
   *and* AUDIO, the primary key becomes `(archetype_id, modality)`, not `archetype_id`.
   **Test this explicitly on arrival** — it is the single most likely thing to break the
   model, and it changes every join in Section 7.
7. **Source the missing `FF_AUDIO_S_BannerPlan`** (see §1.2) before building AUDIO banners.
8. **Then `FF_COMPARE6` becomes buildable** — it needs all six executions, which is why it
   is out of reach today:

```sql
SELECT creative, modality,
       COUNTIF(is_tb)                        AS postint_tb_n,
       SAFE_DIVIDE(COUNTIF(is_tb), COUNT(*)) AS postint_tb_pct
FROM `ff_20_curated.v_response_metrics`
WHERE meta = 'POSTINT' AND is_primary_run
GROUP BY 1, 2;
```

Target reference values from the banner plan: Goyer N=495, Sheridan N=503, total N=998.
Today's READ-only data gives 200 / 198 / 398 — **the CSVs in scope are ~40% of the sample
the banner plans were written against.** Expect READ-only numbers not to reconcile to the
banner plan totals, and say so on any output.

---

## 12. Human-panel calibration (`Final W Tabs`)

The W-tabs are **already-aggregated** crosstabs from a human study (N=800), not
respondent-level data. Load them as a benchmark, not a fact table.

1. Parse the `#page` / `Table N` block structure into long form:
   `(table_no, question_label, banner_group, banner_col, row_label, value, is_pct)`.
   Load `Ban1_Pcnt` and `Ban2_Pcnt` into `ff_00_raw.raw_wtabs_pcnt`, `*_Freq` likewise.
2. Hand-build a crosswalk `dim_wtab_crosswalk` mapping W-tab question labels to
   `question_key`. This cannot be automated reliably — the wording differs. Budget real time
   for it, and cover only the questions you intend to compare (start with `POSTINT`,
   `GFAN1`, `VGFRAN1`, `ACTIVITIES`).
3. Compare like-for-like:

```sql
CREATE OR REPLACE TABLE `ff_30_marts.mart_calibration` AS
SELECT
  x.question_key, x.row_label,
  h.value              AS human_pct,
  s.tb_pct             AS synthetic_pct,
  s.tb_pct - h.value   AS delta,
  SAFE_DIVIDE(s.tb_pct - h.value, NULLIF(h.value, 0)) AS rel_delta
FROM `ff_00_raw.raw_wtabs_pcnt` h
JOIN `ff_20_curated.dim_wtab_crosswalk` x ON h.question_label = x.wtab_label
JOIN `ff_30_marts.mart_banner_read`     s ON s.question_key = x.question_key
                                         AND s.cut_name = 'TOTAL';
```

**Two caveats that must appear on any calibration output:**

- The banner universes differ. W-tabs cut by `GENDER` and `QUADRANTS` (Men <35 / Men 35+ /
  Women <35 / Women 35+); the synthetic banners cut by the 7 banner-plan groups. Only
  `Total` and `Gender` are directly comparable without re-deriving quadrants — which *is*
  doable from `age_band_banner` + `gender_clean`, and worth doing as step 4.
- The W-tab study is a different fielding of the concept. Treat deltas as **directional
  agreement**, not error measurement. The useful question is "do synthetic and human rank
  the same options in the same order", not "is the synthetic number within X points".

Rank correlation (Spearman) on option ordering is the better headline metric here than
absolute delta.

---

## 13. Operations

**Cost.** ~19.5 MB. Storage is effectively free; every query in this plan scans well under
1 GB. The BQML models are small. The only line item that matters is
`AI.GENERATE_TABLE` over 17,301 verbatims — priced per token, so estimate before the full
run and pilot on a single `meta` first.

**Orchestration.** Twelve source files and a fixed transform chain. Do not reach for
Airflow. Either scheduled queries in BigQuery, or a `dbt` project with the layers in
Section 4.1 as models — dbt is worth it mainly for the free test framework mapping onto
Section 8.

**Access.** Persona verbatims and profiles are synthetic and carry no PII, so the sensitivity
is commercial, not personal. Grant analysts `roles/bigquery.dataViewer` on
`ff_20_curated` + `ff_30_marts` only. Keep `ff_00_raw` restricted to the pipeline SA so the
immutability guarantee is real.

**Reproducibility.** Version `gen_raw_schema.py`, `gen_unpivot.py`, all DDL, and the
`AI.GENERATE_TABLE` prompt in this repo. The prompt in particular — a silent edit re-codes
every verbatim and invalidates every downstream comparison.

**Idempotency.** All DDL is `CREATE OR REPLACE`. The pipeline can be re-run end to end at
any time; Gates 1–4 will catch any drift.

---

## 14. Execution checklist

**Phase 1 — Land (½ day)**
- [ ] Create `ff_00_raw` … `ff_30_marts` in one pinned region
- [ ] Slug-rename and upload 12 CSVs to GCS
- [ ] Write `tools/gen_raw_schema.py`
- [ ] Create external tables + materialise raw with `_FILE_NAME`
- [ ] **Gate 1:** 596 / 398 / 398 = 1,392 rows

**Phase 2 — Shape (1–2 days)**
- [ ] Write `tools/gen_unpivot.py`, generate the three UNPIVOT statements
- [ ] Build `stg_response_s21/s22/s23` → `stg_response`
- [ ] Build `dim_archetype` — **Gate 2:** 398 rows, no null `age_band_banner`/`creative`
- [ ] Build `dim_question`, `dim_question_option` — **Gate 3:** 91 / 36
- [ ] Build `fct_response` + `v_response_metrics` — **Gate 4:** 40,178 rows
- [ ] Implement DQ01–DQ14; all green

**Phase 3 — Banners (1–2 days)**
- [ ] `dim_archetype_cuts`
- [ ] `mart_banner_read`
- [ ] Spot-check ≥5 cells against `FF_READ_G_BannerPlan` by hand
- [ ] Run the D4 sensitivity check (with/without the 81 imputed-age rows)
- [ ] Add two-proportion z-tests

**Phase 4 — Models (2–3 days)**
- [ ] `mart_driver_features`
- [ ] Model 1 `LOGISTIC_REG` → `ML.GLOBAL_EXPLAIN`, `ML.EVALUATE`
- [ ] Model 2 `KMEANS` → authored-vector vs discovered-cluster crosstab
- [ ] Provision Vertex connection; pilot Model 3 on one `meta`
- [ ] Audit 100 AI-coded verbatims against human coding
- [ ] Full verbatim coding run → `mart_verbatim_coded`
- [ ] Re-run Model 1 with theme features added
- [ ] Answer-stability report (§10.3)

**Phase 5 — Calibration (2–3 days)**
- [ ] Parse W-tabs into long form
- [ ] Hand-build `dim_wtab_crosswalk` (POSTINT, GFAN1, VGFRAN1, ACTIVITIES)
- [ ] Derive QUADRANTS on the synthetic side
- [ ] `mart_calibration` + Spearman rank correlation

**Blocked / awaiting input**
- [ ] AUDIO + VIDEO respondent CSVs (§11)
- [ ] `FF_AUDIO_S_BannerPlan_2026-07-19.xlsx` (§1.2)
- [ ] Confirm G/S = Goyer/Sheridan with the research lead (inferred, not documented in the CSVs)

---

## Appendix A — Open questions for the research lead

1. **G/S mapping.** Inferred as Goyer/Sheridan from banner project IDs. Confirm.
2. **Cohort `.1` vs `.2`.** Both cohorts within a creative appear structurally identical
   (same questions, same persona construction). Is `.2` a replicate sample, a different
   sample frame, or a different exposure order? The banner plans have an `EXPOSURE ORDER`
   cut, which suggests exposure order — but nothing in the CSVs encodes it. **If exposure
   order is meant to be a banner cut, it has to come from somewhere; right now it cannot be
   built.**
3. **The 998 vs 398 gap.** Banner plans reference 18 sample frames and N=998. The READ CSVs
   contain 398 personas. Is READ genuinely a ~40% subsample, or are CSVs missing?
4. **`17-24` age band.** 81 personas. Confirm the default (→ `18-24`) or supply exact ages.
5. **2.1 vs 2.1X.** Modelled as replicate runs per your direction. Confirm both runs are
   methodologically valid (vs. one being a discarded pilot) — this determines whether
   `is_primary_run` should prefer the standalone file or the combined one.
