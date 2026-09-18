# ARENA Banner Engine

Deterministic, drop-triggered, BigQuery-native banner generation for
synthetic archetype panel concept tests.

No `.sqlx` file names a study, a meta, or a question. Study knowledge
lives in `banner_config`. See `RUNBOOK.md` to execute.

## The source format

Every ARENA export is a fixed envelope with one variable-length block:

```
archetype_* (46 cols, identical in every file)
aat_*       (34 cols, present in ABR, absent in FF)
Q{n}_{question|meta|type|rating_label|rating|selected|qual}   (N x 7)
```

Column discovery is one regex. `meta` is a cell value, not a header
token, so question identity is stable across files even though `Q{n}` is
positional. `Q{n}_type` is a verified taxonomy:

| type | kind | mode | field |
|---|---|---|---|
| 1 | OPEN | none | qual |
| 2 | CODED | single | rating (unlabelled) |
| 4 | CODED | single | selected, always 1 punch |
| 5 | CODED | multi | selected, 1-6 punches |

There is no schema-inference problem, so there is no schema-inference
code. The variability is in content, not structure.

## Design decisions

**Multi-study, no compile-time vars.** One static Dataform release
processes whatever `study_registry` queues. Registering a drop is an
INSERT, not a redeploy.

**Banner columns are data.** `cut_def` plus `int_cut_member` replace six
hand-written `UNION ALL` blocks. The grammar mirrors the header notation
of the reference deliverable: `P1 @ GFAN1` is
`rule_kind='response', meta='GFAN1', code_op='in', codes=[1]`.
`config/030_seed_banner_plans.sql` reproduces all 51 columns of
`305-9113` in 26 rows.

**Punch codes survive to the mart.** The previous pipeline stripped the
numeric code from SELECT answers, which made every response-based cut
inexpressible. `fct_response` carries `option_code` and `option_label`.

**Stub labels come from the data.** No `question_scale_map`, no
per-question hand mapping. Only NETs and type-2 labels are configured,
because those are editorial or absent from the file.

**`run_id` is in the grain.** The old dedup ordered by `source_file` and
kept the first, silently discarding half of a designed replicate.
Primary-run selection is configured.

**Bases are derived.** A question's base is who answered it. Labels are
cosmetic config.

**No silent NULLs.** `PARSE_INT` / `LEAD_INT` instead of `SAFE_CAST`;
every failure lands in `stg_cast_reject` with file, row, column and
reason, and an assertion fails the run above a threshold.

**Conversion is the primary artifact.** `mart_conversion` is binary top
box by column with base, SE and a z against Total. Every row declares
`value_source`, so a model-derived figure can never be mistaken for a
respondent answer.

**No generative AI in the data path.** No embeddings, no clustering, no
AI-proposed columns. `mart_study_profile` ranks cut candidates by η² on
the headline metric, deterministically; a person promotes them.

## Lineage

```
GCS drop
  -> banner_raw.file_cell        op_ingest_raw
  -> banner.stg_cell             block classification
  -> banner.stg_answer           Q-block pivoted back together
     banner.stg_cast_reject      typed-parse failures
  -> banner.dim_question / dim_respondent / int_respondent_attr
     banner.fct_response
     banner.int_cut_member       the cut engine
  -> banner.mart_stub            every figure
     banner.mart_conversion      top box, the headline artifact
     banner.mart_study_profile   the sign-off report
     banner.mart_openend_verbatim
  -> banner.mart_banner_render   printable layout
  -> GCS                      op_export_banner
```

## Status

Written against the 15 reference files in drop-001 and drop-002 and the
`305-9113` target. Not yet executed against live BigQuery — expect a
compile pass and a first-run debug cycle. `RUNBOOK.md` section 3 lists
what the first run should surface.
