# Pushing to sreeram-archetypeid/test-data as a branch

## Why the old files have to come out

Dataform reads one project per branch, rooted at the repo root. The
existing `main` has a complete project there:

```
definitions/dim_question.sqlx      definitions/mart_banner.sqlx
definitions/dim_respondent.sqlx    definitions/mart_stubs.sqlx
definitions/fct_response.sqlx      definitions/stg_clean.sqlx
definitions/int_cut_attrs.sqlx     definitions/v_active_study.sqlx
includes/params.js
workflow_settings.yaml
```

The new project uses the same three root paths. If you merely add files,
you get two `workflow_settings.yaml` candidates, `params.js` throwing on
the missing `vars.study_id` (it has a hard `throw` when the var is
absent), and eight orphan `.sqlx` files referencing `svy.*` tables that
the new project no longer builds. The compile will fail.

So the branch replaces the project. `main` keeps the old one untouched,
and Dataform release configs are per-branch, so both can run side by
side against different datasets.

## Commands

```bash
git clone git@github.com:sreeram-archetypeid/test-data.git
cd test-data

git checkout -b banner-engine

# Remove the old Dataform project from this branch only.
git rm -r definitions includes workflow_settings.yaml

# Copy in the new project (adjust the source path).
cp -r ~/Downloads/arena-banner/. .

git add -A
git status          # expect: 8 deletions, ~36 additions
git commit -m "Banner engine: config-driven cuts, deterministic tabulation, multi-study

- banner_* dataset namespace; no overlap with the svy_* pipeline on main
- cut_def + int_cut_member replace six hardcoded UNION ALL cut blocks
- option_code preserved through fct_response
- run_id restored to the grain; primary-run selection configured
- stub labels read from data; question_scale_map removed
- PARSE_INT/LEAD_INT instead of SAFE_CAST, with stg_cast_reject
- mart_conversion as the primary artifact, with value_source provenance
- no embeddings, clustering, or AI-proposed columns"

git push -u origin banner-engine
```

## Then in Dataform

Do **not** change the existing repository link. Add a second release
configuration on the same Dataform repository:

- Release configuration → **Create**
- Git branch: `banner-engine`
- Release ID: `banner-engine`

Then a workflow configuration pointing at that release, 15-minute cron,
no tag filter.

You now have two release configs on one repo: `main` building `svy.*`,
`banner-engine` building `banner.*`. Neither can touch the other's
tables.

## Reconciliation before you retire anything

Both pipelines read the same CSVs. Once `banner-engine` has run:

```sql
-- Old pipeline, 8 quadrant columns
SELECT stub_label, Total, G_Men_lt35, S_Men_lt35
FROM `archetypeid-staging.svy.mart_stubs_wide`   -- or your export
WHERE ...

-- New pipeline, same figures
SELECT s.stub_label, s.column_id, s.n_stub, s.pct
FROM `archetypeid-staging.banner.mart_stub` AS s
WHERE s.study_id = 'drop-001'
  AND s.column_id IN ('total','q_men_lt35__G','q_men_lt35__S');
```

If the columns both produce agree, the rewrite is validated against
ground you already trust, and the 43 additional columns are new
capability rather than an unverified change. Expect two legitimate
sources of disagreement:

1. **Base counts.** The old `fct_response` deduped replicate runs by
   `ORDER BY source_file`; the new one selects by `primary_run_rule`.
   Different rows survive. Check `dim_respondent.n_runs` before
   concluding either is wrong.
2. **Stub labels.** Old output stripped the punch prefix with a single
   `^\d+\.\s*`; the new `PUNCH_LABEL` strips repeated prefixes, so
   `2. 2. Probably interested` now reads `Probably interested` rather
   than `2. Probably interested`.

## Rolling back

Nothing on `main` changed, and the new datasets are separate. To undo
entirely: delete the Dataform release config, then
`bq rm -r -f -d archetypeid-staging:banner` and the three sibling
datasets.
