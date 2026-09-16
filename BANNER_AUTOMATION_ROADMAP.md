# Generic Survey → BigQuery → Banner Automation — Structural Roadmap

**Scope:** a project-agnostic pipeline that takes *any* wide survey export, profiles it until
the data is understood without human pre-declaration, analyses every question in the table,
and emits a finished banner (crosstab) deck.

**Relationship to the existing work:** `BIGQUERY_MIGRATION_PLAN.md` is the *reference
implementation* for one project (ARENA Fatal Fury, READ modality). This document is the
generalisation of it: every place that plan hardcodes a fact, this one specifies where that
fact must instead be **discovered, registered, or configured**.

**Last updated:** 2026-09-16

---

## Part I — Progress to date

### What exists

| Asset | State | Notes |
|---|---|---|
| `BIGQUERY_MIGRATION_PLAN.md` | **Merged** (PR #1) | 1,146 lines. Execution-ready, measured against real files. |
| Source profiling of 12 READ CSVs | **Done** | 1,392 rows, 40,178 fact rows, 398 personas, 91 question keys — all measured, not estimated. |
| Data-quality catalogue (D1–D11) | **Done** | Embedded newlines, doubled option codes, packed multi-selects, age-format drift, sentinel codes. |
| Target architecture (raw → staging → curated → marts) | **Specified** | Layering, naming, clustering, chunking strategy. |
| Banner-plan reverse engineering | **Done** | 3 sheets, 7 banner groups, 54 cut columns, 6-metric vocabulary (`N`, `TB %`, `T2B %`, `B2B%`, `BOT%`, `MEAN`). |
| DQ assertion suite (DQ01–DQ16) | **Specified** | Thresholds baselined from the measured numbers. |
| Analysis layer (driver model, KMeans, verbatim coding) | **Specified** | Not yet run. |

### What is *not* done

- **Nothing is built in BigQuery yet.** Phases 1–5 of the §14 checklist are all unchecked.
  The plan is a design, not a deployment.
- **No code in the repo.** `tools/gen_raw_schema.py` and `tools/gen_unpivot.py` are
  referenced by the plan but do not exist.
- **Everything is single-project.** The 12 filenames, the 46 attribute columns, the
  20/35/36 section split, the `40,178` reconciliation target, the `Goyer`/`Sheridan` mapping
  and the banner cut list are all written into the plan as constants. A second study cannot
  reuse any of it without a rewrite.
- **Blocked inputs remain blocked:** AUDIO/VIDEO respondent CSVs, `FF_AUDIO_S_BannerPlan`,
  and the five open questions in Appendix A.

### The gap this roadmap closes

> The current plan tells a human how to migrate **one** study.
> The target is a system where a new study is a **config file and a file drop**, and the
> banner comes out the other end.

---

## Part II — Design principles

1. **Discover, don't declare.** Structure (which columns are identity, which are question
   blocks, how many sections, what the scale is) is *inferred from the data* and written to a
   machine-readable profile. Humans only confirm or override.
2. **Profile is the contract.** Every downstream stage reads the profile artefact, never the
   raw files directly. A profile diff is the review surface for "did the data change?".
3. **Config over code.** New study = new YAML. If a new study requires new SQL, the engine
   has a gap — fix the engine, not the study.
4. **Long-and-tidy in the middle, wide only at the edges.** One `fct_response` grain serves
   every metric, every cut and every model. Widening happens only in the renderer.
5. **Thresholds are baselined, not hardcoded.** DQ gates derive their expected values from
   the profile of the run that produced them, so a new study gets a working test suite for
   free.
6. **Every override is an artefact.** Human judgement (an ambiguous age band, a scale
   polarity, a cut definition) lives in a versioned override file with a reason field —
   never inline in a query.
7. **Nothing is silently dropped.** Replicates, sentinels, unparseable values and out-of-scope
   rows are all flagged and retained, never deleted.

---

## Part III — The maturity ladder

The roadmap is organised as five levels. Each is independently shippable and each one
removes a category of human work.

| Level | Name | What a new study costs | Exit criterion |
|---|---|---|---|
| **L0** | Bespoke | ~2 weeks of analyst SQL | *(today)* |
| **L1** | Templated | 2–3 days: copy repo, edit constants | Fatal Fury READ rebuilt end-to-end from code in this repo |
| **L2** | Profiled | ½ day: drop files, review profile | Profiler explains an *unseen* export with no code change |
| **L3** | Declarative banners | 2 hours: write a banner YAML | Banner for a new study built without touching SQL |
| **L4** | Zero-config | Minutes: drop files, accept defaults | Banner auto-proposed from the profile; human only edits the diff |

Do not attempt L4 before L2 is stable. The value of L4 is entirely dependent on the profiler
being trustworthy.

---

## Part IV — Stage architecture

```
   files          ┌──────────┐   profile.json   ┌──────────┐
  (any shape) ──► │ A. LAND  │ ───────────────► │ B. PROFILE│
                  └──────────┘                  └────┬─────┘
                                                     │ structure + roles
                                                ┌────▼─────┐
                                                │C. UNDERSTAND│  semantic layer
                                                └────┬─────┘  (questions, scales, options)
                                                     │
                                                ┌────▼─────┐
                                                │D. NORMALISE│ generic unpivot → fct_response
                                                └────┬─────┘
                                   ┌─────────────────┼─────────────────┐
                              ┌────▼─────┐      ┌────▼─────┐      ┌────▼─────┐
                              │E. METRICS│      │ F. CUTS  │      │H. QA GATES│
                              └────┬─────┘      └────┬─────┘      └──────────┘
                                   └────────┬────────┘
                                       ┌────▼─────┐         ┌──────────┐
                                       │G. BANNER │ ──────► │I. ANALYSE│
                                       └────┬─────┘         └────┬─────┘
                                            └────────┬───────────┘
                                                ┌────▼─────┐
                                                │J. PUBLISH│  xlsx / pptx / dashboard
                                                └──────────┘
```

---

### Stage A — Land & register

**Goal:** get bytes into object storage with a stable identity, losing nothing.

- **Source registry** (`registry.source_file`): one row per landed file — original name,
  slug, sha256, byte size, row count, arrival time, study id, declared modality, load status.
  The slug rule replaces the hand-written rename table (plan D8): strip diacritics, collapse
  whitespace and em-dashes, lowercase, ASCII-only.
- **Immutability:** raw bucket is write-once, versioned; the pipeline SA is the only writer.
- **Load flags are fixed defaults, not per-project decisions:** quoted newlines allowed,
  every column `STRING`, no autodetect, `_FILE_NAME` pseudo-column materialised.
  The plan's D1 finding (8,957 fields with embedded newlines) is the reason this is a
  default and not a flag someone remembers to set.
- **Encoding + BOM detection** on arrival, recorded in the registry rather than assumed.

**Generalisation note:** accept CSV, TSV, XLSX (per sheet) and Parquet at this stage. Format
is a registry attribute; everything downstream sees a raw all-STRING table.

---

### Stage B — Profile (the heart of "the data is understood")

**Goal:** produce `profile.json` — a complete machine-readable description of an export that
nobody has looked at yet.

**B1. Column role classification.** Each column is assigned exactly one role:

| Role | Detection signal |
|---|---|
| `identity` | High cardinality ≈ row count, stable across files, name matches id-like patterns |
| `partition` | Low cardinality, constant within a file, varies across files (e.g. group/sample name) |
| `attribute` | Constant per identity value across *all* files in which that identity appears |
| `question_block` | Participates in a repeating column-name pattern (see B2) |
| `metadata` | Timestamps, durations, status/ingest columns |
| `unknown` | Fails all of the above → surfaced for human labelling, never guessed |

The attribute test is the strong one: group by the identity column across files and check for
byte-identical values. The reference project passes it cleanly (zero mismatches across 46
attribute columns) — a *failure* is itself a finding worth reporting.

**B2. Block detection.** Infer the repeating question-block shape rather than assuming it:
tokenise column names, find the maximal repeating suffix set with a varying ordinal prefix
(the reference data yields a 7-column block: `question, meta, type, rating_label, rating,
selected, qual`). Record block width, block count, and the fixed-prefix width. Total columns
must reconcile to `prefix + width × count`; if not, stop.

**B3. Value profiling.** Per column: null rate, distinct count, top-K values, length stats,
inferred primitive type, regex-family clustering (dates, currency, ranges, packed lists,
prefixed codes). This is what mechanically produces the D2–D11 class of findings on a new
study instead of a human noticing them.

**B4. Anomaly detection.** Named detectors, each emitting a finding with evidence and a
proposed handler:

| Detector | Proposed handler |
|---|---|
| Repeated code prefix (`1. 1. label`) | Idempotent prefix-strip regex |
| Packed multi-value (consistent delimiter inside a field) | Split to `ARRAY<STRUCT<code,label>>` |
| Mixed-format column (buckets + points + hybrids) | Emit `*_raw`, `*_exact`, `*_band`, `*_is_imputed` |
| Case/whitespace drift | Normalised companion column, raw preserved |
| Sentinel codes (≥ 90, "None of the above", "Other") | Excluded from scale stats, counted separately |
| Cross-file overlap on `(identity, question)` | **Replicate**, not duplicate — see B5 |
| Unicode confusables (curly quotes, NBSP) | Preserve raw; normalise only in grouping keys |

**B5. Replicate detection — generalised.** For every `(identity, question_key)` that appears
in more than one file, compare answers. Equal answers ⇒ true duplicate (flag for dedupe
decision). Unequal answers ⇒ **replicate run**. The engine then:
- creates a `dim_run` row per (file, section),
- includes `run_id` in the fact grain,
- computes `is_primary_run` by a declared, auditable rule (default: earliest-arriving run;
  override per study),
- emits an **answer-stability report** for free.

This is the general form of the 2.1X finding. It should never again depend on an analyst
spotting it.

**B6. Profile output.** `profile.json` + a human-readable `PROFILE.md`, both versioned per
run. The diff between two profiles is the primary "has the data changed?" review artefact.

**Gate B:** profile is complete, zero `unknown` roles unresolved, reconciliation arithmetic
balances.

---

### Stage C — Understand (semantic layer)

**Goal:** turn structure into meaning — the question universe, its scales, its option space.

- **`dim_question`** keyed on a stable identity. Positional `Q{n}` is *never* the key; the key
  is a hash of `(meta_code, question_text, type)`. This makes the key stable across sections,
  files, waves and modalities.
- **`dim_question_option`**: the observed option universe per question, with `option_code`,
  cleaned `option_label`, `is_sentinel`, and `scale_max` derived per question *excluding*
  sentinels. Hardcoding a 5-point scale is the single most common way to produce wrong
  BOT/B2B numbers — the reference data mixes 4-, 5- and 6-point items.
- **Scale polarity detection.** Whether `1` is best or worst is a study-level convention that
  must be *stated* (the reference banner plans state it in a header cell: "1 = best/top").
  The engine reads it from config, and cross-checks against the option labels with a simple
  lexical heuristic ("one of my favorites" vs "never"). A disagreement blocks the run.
- **Question typology**, normalised across studies: `open_end`, `single_select`,
  `multi_select`, `scale`, `numeric`, `select_plus_probe`. The source's own type codes are
  mapped into this vocabulary via a per-study mapping table, with fill-pattern evidence
  (which of rating/selected/qual are populated) used to validate the mapping.
- **Question taxonomy tagging**: `demographic`, `screener`, `behavioural`, `exposure`,
  `outcome`. Drives default banner ordering and default cut candidates in Stage F.

**Gate C:** every question has a type, a scale_max (where applicable), and a taxonomy tag;
option labels carry no residual code prefix.

---

### Stage D — Normalise

**Goal:** one fact grain, generated not hand-written.

- **Generated unpivot.** A generator reads the profile's block shape and emits the UNPIVOT /
  union SQL for any block width and count. No analyst writes a 36-block statement by hand.
- **Grain:** `(study_id, modality, identity_id, run_id, question_key, item_index)`.
  Modality and study are in the grain from day one, so adding AUDIO/VIDEO — or an entirely
  different study — is `UNION ALL`, never a migration.
- **Parse + type:** code/label split, multi-select explode to array, numeric cast to
  `SAFE_CAST`, verbatim preserved verbatim. Unparseable values land in `parse_error` with the
  raw string retained — never dropped.
- **`fct_response`** plus a `v_response_metrics` view that adds the per-row boolean flags
  (`is_tb`, `is_t2b`, `is_bot`, `is_b2b`, `primary_code`, `is_sentinel`). Every metric in the
  system is a `COUNTIF` over these flags — which is what makes Stage E generic.
- **`dim_respondent`** (the generalisation of `dim_archetype`): one row per identity, all
  attribute columns, plus derived normalised companions (`*_clean`, `*_band`, `*_is_imputed`,
  parsed numeric ranges).

**Gate D:** fact row count reconciles to the profile's predicted total; zero orphans against
`dim_respondent`; exactly one `is_primary_run` per (identity, question_key).

---

### Stage E — Metric engine

**Goal:** "completely analyses the table" — every question gets every metric that is valid
for its type, with no per-question SQL.

**Metric registry** — declarative, one row per metric, with an applicability predicate:

| Metric | Applies to | Definition |
|---|---|---|
| `N` | all | base count of valid respondents in the cell |
| `%` per option | single/multi select | share of base selecting each option |
| `TB %` | scale | `option_code = best_code` |
| `T2B %` | scale (max ≥ 4) | two codes nearest best |
| `BOT %` / `B2B %` | scale | mirror, computed from per-question `scale_max` |
| `MEAN` | scale/numeric | mean over non-sentinel codes |
| `sentinel %` | select | explicit row per sentinel (None/Other), never folded into base |
| `multi-select note` | multi | flags that percentages may exceed 100% |
| `theme %` | open-end | **from Stage I coding** — the row the manual process leaves blank |
| `sig` | any comparative | two-proportion z / t-test vs. the designated base column |

Rules that must be enforced by the engine, not by the analyst:
- Base definition is explicit per metric (`answered`, `asked`, `total`) and printed in the output.
- Sentinels excluded from `MEAN`/`BOT`/`B2B` and from `scale_max`.
- Small-base suppression: cells below a configured `n` render as a symbol, not a number.
- Multi-run data pinned to `is_primary_run` for anything crossing sections.

Output is one long table: `(question_key, item, metric, cut_name, cut_value, value, base_n,
sig_flag)`. Everything else is a view of this.

---

### Stage F — Cut compiler

**Goal:** banner columns defined declaratively, from either data source family.

Two families, one interface:
- **Attribute cuts** resolve against `dim_respondent` (gender, age band, race, income band,
  parent status, relationship status, region).
- **Behavioural cuts** resolve against responses — top-box on a named question — and are
  materialised into a persona-level flag table first, then joined back. The reference banner
  needs 23 such columns (media behaviours, game-title appeal, genre fandom, outcome top-box).

**Banner spec (YAML)** — the whole point of L3:

```yaml
banner: standard_concept_test
base:   { filter: "is_primary_run", label: "Total" }
suppress_below_n: 30
sig_test: { type: two_proportion_z, alpha: 0.05, against: Total }
groups:
  - name: "GENDER: MALES"
    columns:
      - { label: "Male",    where: "gender_clean = 'Male'" }
      - { label: "M18-24",  where: "gender_clean = 'Male' AND age_band = '18-24'" }
  - name: "MEDIA BEHAVIORS: TOP BOX ONLY"
    from: response_flag           # behavioural family
    columns:
      - { label: "Play video games", question: "ACTIVITIES::play_video_games", metric: TB }
rows:
  include: all_questions          # "completely analyses the table"
  order:   [demographic, screener, behavioural, exposure, outcome]
  metrics_by_type:
    scale:         [N, TB, T2B, B2B, BOT, MEAN]
    single_select: [N, pct_by_option]
    multi_select:  [N, pct_by_option, multi_note]
    open_end:      [N, theme_pct]
```

**Two directions of travel, both needed:**
1. **Spec → banner** (build from YAML).
2. **Existing banner plan → spec** (an importer that parses a legacy banner-plan workbook:
   header block for project metadata and scale convention, the group row and column row for
   cut definitions, the question/metric columns for rows). This is what lets an in-flight
   project adopt the engine without re-authoring its banner by hand.

**L4 behaviour:** when no spec is supplied, propose one from the profile — every question as
a row, every low-cardinality demographic attribute as a cut group, outcome-tagged questions
as top-box behavioural cuts. The human reviews a *diff against the proposal* rather than
authoring from scratch.

---

### Stage G — Banner build & render

- **`mart_banner`**: the metric long-table cross-joined with the resolved cut set, one row per
  (row, metric, column). Computed once, pivoted at presentation time.
- **Renderer** targets, from the same mart:
  - **XLSX** in the legacy plan layout — header block (project name/id/date/QRE/scale
    convention), group row, column row, then per-question metric blocks. Matching the
    incumbent layout exactly is what makes adoption painless.
  - **PPTX chart report** for the headline questions.
  - **Long table** for BI tools and for downstream modelling.
- **Significance marks** rendered as letters/arrows per the house convention.
- **Provenance footer on every output**: study id, profile hash, spec hash, build timestamp,
  git sha. A banner you cannot trace to an input version is not evidence.

---

### Stage H — QA gates (runs continuously, not at the end)

- **Structural gates** (per stage, as listed above) — the run halts, it does not warn.
- **Reconciliation gates** with thresholds *baselined from the profile* — row counts,
  respondent counts, question counts, per-cohort counts, replicate-key counts.
- **Semantic gates** — no residual code prefixes, `scale_max` within sane bounds, every
  open-end has text, every select has ≥1 option, non-null banner bands.
- **Sensitivity gates** — any metric whose value materially moves when imputed rows are
  excluded is flagged on the output, not silently published.
- **Golden-output regression** — a known study's banner is rebuilt on every engine change and
  diffed cell-by-cell against the accepted version. This is the safety net that makes the
  engine changeable.
- **Human spot-check ritual** — ≥5 cells hand-verified against the legacy workbook on first
  build of any study. Automation earns trust once, per study.

---

### Stage I — Analysis layer (beyond what a crosstab can do)

Generic forms of the three models in the reference plan:

1. **Driver model** — logistic regression on the study's designated *outcome* question
   (tagged in Stage C), features assembled automatically from demographics + behavioural
   flags + segmentation attributes. Report global explanations and coefficient signs; treat
   AUC as a sanity check. Guard rails: minimum N per feature, automatic feature-count cap,
   and an explicit "hypothesis-generating, not predictive" caveat below a configured N.
2. **Segmentation** — clustering on behaviour, crosstabbed against any authored segmentation
   the study ships. A scrambled crosstab is a reportable finding about the sample, not a bug.
3. **Verbatim coding** — LLM structured extraction over every open-end, producing sentiment,
   primary/secondary theme and study-specific boolean flags. This is what fills the
   `theme %` metric rows that the manual process marks "not tabulated here". Non-negotiables:
   temperature 0, prompt versioned in git, batch by question group, human audit of a sample
   before any coded output is published, and re-coding on any prompt change.
4. **Stability report** — replicate agreement per question, wherever Stage B found replicates.

Coded themes feed **back** into the driver model as features, and back into the banner as
rows. That loop is the actual justification for the warehouse.

---

### Stage J — Publish & operate

- **Orchestration:** scheduled queries or dbt. Not Airflow — the DAG is a fixed chain over a
  dozen files.
- **Layer permissions:** raw restricted to the pipeline SA (so immutability is real),
  curated + marts readable by analysts.
- **Cost:** trivial at this data size; the only metered line is LLM verbatim coding. Estimate
  before a full run, pilot on one question group.
- **Idempotency:** all DDL `CREATE OR REPLACE`; the chain is re-runnable end to end at any time.
- **Versioning:** profile, spec, prompt, DDL and generator scripts all in git. Every output
  carries the hashes.

---

## Part V — Delivery plan

| Phase | Deliverable | Exit test | Est. |
|---|---|---|---|
| **P1 — Reference build** | Execute the existing plan for READ in code (`tools/`, DDL, DQ suite) | Gates 1–4 green; ≥5 banner cells match the legacy workbook | 3–5 d |
| **P2 — Profiler** | Stage A + B; `profile.json` + `PROFILE.md` + anomaly detectors | Profiler reproduces every D1–D11 finding on the reference data **with no study-specific code** | 5–7 d |
| **P3 — Semantic + normalise engine** | Stage C + D driven entirely by the profile | Reference `fct_response` rebuilt byte-identical via the generic path | 4–6 d |
| **P4 — Metric + cut engine** | Stage E + F, banner YAML, legacy-plan importer | Reference banner reproduced from YAML only, zero bespoke SQL | 5–7 d |
| **P5 — Renderer + gates** | Stage G + H, XLSX/PPTX output, golden regression | Analyst-acceptable workbook; regression suite wired to CI | 4–5 d |
| **P6 — Analysis layer** | Stage I, all four analyses parameterised | Driver ranking + coded verbatims published for the reference study | 5–8 d |
| **P7 — Second study** | Onboard a genuinely different export | New study to banner in ≤ ½ day, no engine changes | 2–3 d |

**P7 is the only phase that proves the rest.** Until a second, structurally different study
runs through untouched, the engine is a template wearing a framework costume.

---

## Part VI — Risks

| Risk | Why it bites | Mitigation |
|---|---|---|
| Profiler over-confidence | A wrong inferred role corrupts everything downstream silently | Human confirmation gate on the profile; `unknown` is never auto-guessed |
| Scale polarity flipped | Every TB/BOT number inverts and looks plausible | Config-stated, lexically cross-checked, run blocks on disagreement |
| Per-question `scale_max` ignored | Wrong BOT/B2B on non-5-point items | Derived per question in `dim_question_option`; DQ gate on range |
| Replicates treated as duplicates | Silent loss of real answers, or double-counted bases | Generic replicate detector; `run_id` in grain; `is_primary_run` mandatory for cross-section metrics |
| Small-N modelling oversold | 398 respondents cannot support a predictive claim | Automatic caveat + feature cap below configured N |
| Verbatim prompt drift | Silently re-codes history, invalidates comparisons | Prompt in git, hash on every output, re-code on change |
| Over-generalising too early | L4 features built on an untrusted profiler | Ladder order enforced: no L4 before L2 is stable |
| Legacy layout mismatch | Analysts reject an unfamiliar workbook | Importer + renderer both target the existing plan layout |

---

## Part VII — Definition of done

The system is done when all of the following hold for a study nobody on the team has seen:

1. Files land; the profiler explains the structure with no code change.
2. A human reviews `PROFILE.md`, resolves the `unknown` columns and any ambiguous mapping,
   and records each decision with a reason.
3. The banner spec is proposed automatically and accepted or edited as a diff.
4. Every question in the table appears in the banner with every metric valid for its type —
   open-ends included, coded, not blank.
5. All gates pass; the sensitivity checks are clean or flagged on the output.
6. The workbook, the deck and the long table all carry the same provenance hashes.
7. Total human time: hours, not weeks.

---

## Appendix — Carry-over open items from the reference project

These remain outstanding and are inputs to P1, not to the generic engine:

- AUDIO + VIDEO respondent CSVs (not yet supplied).
- `FF_AUDIO_S_BannerPlan_2026-07-19.xlsx` (absent from the support folder).
- Confirm G/S = Goyer/Sheridan (inferred from banner project IDs, not documented in the CSVs).
- Confirm the `17-24` age-band default (81 respondents) or supply exact ages.
- Confirm both section-2.1 runs are methodologically valid, which determines the
  `is_primary_run` rule.
- Explain the N=998 (banner plans) vs 398 (READ CSVs) gap.
- `EXPOSURE ORDER` is a banner cut in the plans but is not encoded anywhere in the CSVs —
  it cannot be built until a source for it exists.
