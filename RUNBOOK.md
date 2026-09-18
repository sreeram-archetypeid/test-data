# RUNBOOK

## 1. One-time setup

```bash
bq query --use_legacy_sql=false < config/010_schema.sql
bq query --use_legacy_sql=false < config/020_seed_formats.sql
bq query --use_legacy_sql=false < config/030_seed_banner_plans.sql
```

Then in Dataform: connect the repo, create a release configuration on
`main`, and a workflow configuration on a 15-minute cron with tag filter
left empty (all tags).

There are no compilation variables. Do not add any — the whole point of
the multi-study design is that one release serves every drop.

## 2. First run against drop-001 and drop-002

```bash
bq query --use_legacy_sql=false < config/040_register_drop.sql
```

Then trigger the workflow manually once. Expected sequence:

| Tag | What runs | Status after |
|---|---|---|
| `ingest` | `op_ingest_raw` | `pending` → `ingested` |
| `staging` | `stg_cell`, `stg_answer`, `stg_cast_reject` | |
| `curated` | `dim_*`, `int_*`, `fct_response` | |
| `marts` | `mart_stub`, `mart_conversion`, `mart_study_profile` | |
| `dq` | six assertions | |
| `render` + `export` | only for studies at `configured` | → `published` |

drop-001 is pre-configured (`headline_meta = POSTINT`, `topbox_codes = [1,2]`),
so set its status to `configured` to get a banner on the first pass:

```sql
UPDATE `archetypeid-staging.banner_config.study_registry`
   SET status = 'configured' WHERE study_id = 'drop-001';
```

drop-002 will build marts but not render, because `headline_meta` is NULL.
See section 6.

## 3. Expected first-run findings

These are known from the reference files and are not failures of the
pipeline:

- `assert_cast_reject_rate` should pass but `stg_cast_reject` will not be
  empty. At minimum one ABR K9 row has `archetype_age_range = '9 years old'`.
  Check the export at `gs://…/drop-002/dq/`.
- FF `POSTINT` punch labels arrive doubled (`2. 2. Probably interested`).
  `PUNCH_LABEL` strips repeated prefixes; verify stub labels read
  `Probably interested`, not `2. Probably interested`.
- FF has 20 questions per file across 12 files at three run levels
  (`2_1X`, `2_2`, `2_3`). `is_primary_run` should select one per
  respondent × question under `standalone_wins`. Count distinct
  respondents in `dim_respondent` against the expected 398.
- ABR produces no `cell` attribute at all, so `int_cut_member` emits no
  nested columns and the `band_cell` header line is blank. Correct.

## 4. Adding drop-003

**Automatic, no action:** the scheduled query registers the drop as
`pending`, `op_ingest_raw` loads it, staging and curated build,
`mart_study_profile` is populated.

**Manual, four decisions.** Read `banner.mart_study_profile` for the study.
It gives you, per meta: tabulation kind, response mode, level count,
sample labels, minimum level base, η² against the headline metric, and a
boolean `is_cut_candidate` — ranked.

1. **`headline_meta`** — which meta is the conversion question. Nothing
   in the file states this.
2. **`topbox_codes`** — which punches count as converted. Check the
   sample labels: a scale can be inverted.
3. **`cut_def` rows** — promote candidates into a banner plan. The
   ranking does the analytical work; the grouping and column titles are
   editorial.
4. **`banner_plan_id`** on the study, then `status = 'configured'`.

If the format is new, also add one `format_registry` row (the four
regexes) and, if arms exist, a `cell_regex`.

For a drop reusing an existing format with an existing plan, steps 1–4
are already answered in `format_registry` and the flow is genuinely
hands-off.

## 5. Rebuilding

```sql
UPDATE `archetypeid-staging.banner_config.study_registry`
   SET status = 'rebuild' WHERE study_id = 'drop-001';
```

Every incremental model deletes and reloads that study on the next run.
No full refresh needed, no other study touched.

## 6. drop-002 conversion metric — open decision

ABR has no closed-ended conversion question:

| File | Interest question | Type |
|---|---|---|
| ABR K3 / K9 | `KPOSTINT` | 1 — free text only |
| ABR HTR adult | none | — |

The only structured conversion signal is `aat_top_box_category`, which is
model-generated from the verbatim. `mart_conversion` will use it, but
tags every row `value_source = 'derived'`, and
`assert_conversion_provenance` fails if that tag is ever missing.

Before drop-002 goes to a client, one of:

1. **Validate on FF.** Run the same generator over FF verbatims and
   compare its verdict to the actual `POSTINT` punch. FF has both, so
   this yields a measured agreement rate and costs nothing but compute.
2. **Change the instrument.** Give kid panels a 3-point pictorial scale.
   Removes the problem rather than measuring it.

Until one is done, `headline_meta` stays NULL for drop-002 and the
conversion export is marked derived.

## 7. Open ends — deliberately not coded

`mart_openend_verbatim` exports verbatims uncoded. There is no
clustering step and no model inventing a taxonomy, because a generated
coding frame is non-deterministic at the structural level: the same
questionnaire can yield different categories on a later run, and nothing
downstream flags it.

When this is switched on, the design is:

- human-authored fixed code frame per meta, versioned
- one bounded grading call per verbatim returning a multi-hot over that
  frame, scoped to that cell only
- cached on `hash(verbatim_text, frame_version, model_version)`, so a
  re-run is a cache read and the same input always yields the same output
- calibrated against Table 44 of `305-9113`, which is 285 human-coded
  verbatims — report per-code precision and recall before shipping

`mart_openend_verbatim.verbatim_hash` is already present as the cache key.

## 8. What is deliberately absent

- No embeddings, no `ML.KMEANS`, no `VECTOR_SEARCH`, no Vertex AI index
  endpoint.
- No AI-proposed banner columns. `mart_study_profile` ranks
  deterministically; a person promotes.
- No `SAFE_CAST`. Use `PARSE_INT` / `LEAD_INT` from `includes/constants.js`;
  failures go to `stg_cast_reject`.
- No `question_scale_map`. Stub labels are read from the data. Only NETs
  and type-2 rating labels are configured.
- No compile-time `study_id`.

## 9. Known gaps

- `op_ingest_raw` and `op_export_banner` build SQL strings inside a
  `WHILE` loop. This is the ugliest code in the repo and exists only to
  satisfy the BigQuery-native constraint. If that constraint is relaxed,
  both become short Python scripts with unit tests, and the repo gets
  better.
- Grid item text is derived from `question_text` rather than a dedicated
  field, because the export has none. Items sharing a meta are
  distinguished by their full question text.
- `z_vs_total` compares a subgroup against a Total that contains it.
  Directional indicator, not a formal test.
- Nothing has been executed against live BigQuery. Expect a compile pass
  and a first-run debug cycle, particularly on the two `EXECUTE IMMEDIATE`
  blocks.
