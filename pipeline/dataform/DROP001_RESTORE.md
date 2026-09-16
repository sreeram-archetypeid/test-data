# Drop-001 Dataform restore (pre–drop-002)

Recovered from the morning chat that produced the working G/S × gender × age banner.

## Files (paste into Dataform UI or sync from repo)

| File | Role |
|---|---|
| `includes/params.js` | Requires `study_id` + `format_id` vars |
| `workflow_settings.yaml` | Defaults: `drop-001` / `arena_ff_v1` |
| `definitions/stg_clean.sqlx` | FF answers+respondents → clean |
| `definitions/dim_respondent.sqlx` | Gender / age / race / location |
| `definitions/dim_question.sqlx` | SCALE / SELECT / OTHER |
| `definitions/fct_response.sqlx` | Long answers |
| `definitions/int_cut_attrs.sqlx` | **G/S from `-FF-([GS])-`**, quadrants at 35, arm nests |
| `definitions/mart_stubs.sqlx` | Stubs + Total/gender/quadrants/**arm/arm_gender/arm_quadrants** |
| `definitions/mart_banner.sqlx` | Tidy top-2-box metrics |
| `definitions/v_active_study.sqlx` | Registry check for vars |
| `config/ensure_ff_banner_params.sql` | `age_split_at=35` for FF |

Optional later: `stg_clean_dual_ff_abr.sqlx` (ABR+FF) — **do not use** for this restore.

## Run order

1. BigQuery: run `config/ensure_ff_banner_params.sql`
2. Dataform: set vars `study_id=drop-001`, `format_id=arena_ff_v1`
3. Replace each definition file above in the Dataform repo UI (or push + pull)
4. **Compiled → Start execution** (full graph)
5. Smoke:

```sql
SELECT sample_arm, COUNT(DISTINCT respondent_id) n
FROM `archetypeid-staging.svy.int_cut_attrs`
WHERE study_id = 'drop-001'
GROUP BY 1 ORDER BY 1;
-- expect G ~200, S ~198

SELECT cut_id, cut_value, COUNT(*) n
FROM `archetypeid-staging.svy.mart_stubs`
WHERE study_id = 'drop-001' AND stub_kind = 'base'
  AND cut_id IN ('arm', 'arm_quadrants')
GROUP BY 1, 2 ORDER BY 1, 2;
```

6. Rebuild G/S banner: paste `banners/restore_ban1_gs_pcnt.sql` (in chat / repo)

## Constraints that made drop-001 easy

- Vars only — no study hardcodes inside models (except BQ config tables)
- G/S from filename `-FF-([GS])-`
- Age split from `banner_params` (`35`)
- `mart_stubs` emits arm nests used by Ban1 G/S export
- Scale nets from `svy_config.scale_*` + `question_scale_map` for `arena_ff_v1`
