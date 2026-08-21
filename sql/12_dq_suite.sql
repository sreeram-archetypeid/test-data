-- Data-quality suite. Every expected value was reconciled from the source CSVs
-- and re-verified offline in DuckDB (tools/validate_local.py), so a mismatch is
-- a real defect, not a tolerance to be widened.
--
-- Three thresholds differ from BIGQUERY_MIGRATION_PLAN.md Section 8, because
-- the plan's values are wrong against the actual data:
--   DQ07 - the plan's 81 is the RAW FILE-ROW count; at persona grain it is 22.
--   DQ08 - 3 open-end rows genuinely have no verbatim; the plan asserts 0.
--   DQ11 - single-select scales run 1..6; the plan's flat 2..12 fails 6
--          questions because multi-selects legitimately reach 20.
WITH checks AS (
  SELECT 'DQ01' AS id, 'fct_response rows' AS check_name,
         (SELECT COUNT(*) FROM `ff_20_curated.fct_response`) AS got, 40178 AS want
  UNION ALL SELECT 'DQ02', 'distinct personas',
    (SELECT COUNT(DISTINCT archetype_id) FROM `ff_20_curated.fct_response`), 398
  UNION ALL SELECT 'DQ02b', 'dim_archetype rows',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_archetype`), 398
  UNION ALL SELECT 'DQ03', 'dim_question rows',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_question`), 91
  UNION ALL SELECT 'DQ03b', 'distinct meta',
    (SELECT COUNT(DISTINCT meta) FROM `ff_20_curated.dim_question`), 36
  UNION ALL SELECT 'DQ03c', 'duplicate question_key',
    (SELECT COUNT(*) FROM (SELECT question_key FROM `ff_20_curated.dim_question`
                           GROUP BY 1 HAVING COUNT(*) > 1)), 0
  UNION ALL SELECT 'DQ04a', 'personas in G.1',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_archetype` WHERE cohort_code='G.1'), 100
  UNION ALL SELECT 'DQ04b', 'personas in G.2',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_archetype` WHERE cohort_code='G.2'), 100
  UNION ALL SELECT 'DQ04c', 'personas in S.1',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_archetype` WHERE cohort_code='S.1'), 98
  UNION ALL SELECT 'DQ04d', 'personas in S.2',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_archetype` WHERE cohort_code='S.2'), 100
  UNION ALL SELECT 'DQ05', 'orphan facts',
    (SELECT COUNTIF(creative IS NULL) FROM `ff_20_curated.fct_response`), 0
  UNION ALL SELECT 'DQ06', 'null age_band_banner',
    (SELECT COUNTIF(age_band_banner IS NULL) FROM `ff_20_curated.dim_archetype`), 0
  UNION ALL SELECT 'DQ06b', 'null creative',
    (SELECT COUNTIF(creative IS NULL) FROM `ff_20_curated.dim_archetype`), 0
  UNION ALL SELECT 'DQ07', 'imputed-age personas',
    (SELECT COUNTIF(age_band_is_imputed) FROM `ff_20_curated.dim_archetype`), 22
  UNION ALL SELECT 'DQ08', 'type-1 rows missing verbatim',
    (SELECT COUNTIF(q_type='1' AND qual_text IS NULL)
     FROM `ff_20_curated.fct_response`), 3
  UNION ALL SELECT 'DQ09', 'type-4/5 rows with no options',
    (SELECT COUNTIF(q_type IN ('4','5') AND ARRAY_LENGTH(selected_options)=0)
     FROM `ff_20_curated.fct_response`), 0
  UNION ALL SELECT 'DQ10', 'labels keeping a leading code',
    (SELECT COUNT(*) FROM `ff_20_curated.fct_response` f, UNNEST(f.selected_options) o
     WHERE REGEXP_CONTAINS(o.option_label, r'^\s*\d+\.')), 0
  UNION ALL SELECT 'DQ11', 'single-select scale_max outside 1..6',
    (SELECT COUNT(*) FROM (SELECT DISTINCT question_key, scale_max
                           FROM `ff_20_curated.dim_question_option`
                           WHERE scale_max IS NOT NULL) s
     JOIN `ff_20_curated.dim_question` q USING (question_key)
     WHERE NOT q.is_multi_select AND (s.scale_max < 1 OR s.scale_max > 6)), 0
  UNION ALL SELECT 'DQ11b', 'multi-select questions',
    (SELECT COUNTIF(is_multi_select) FROM `ff_20_curated.dim_question`), 9
  UNION ALL SELECT 'DQ12', 'verbatim count',
    (SELECT COUNTIF(qual_text IS NOT NULL) FROM `ff_20_curated.fct_response`), 17301
  UNION ALL SELECT 'DQ13', 'keys without exactly one primary run',
    (SELECT COUNT(*) FROM (SELECT archetype_id, question_key
                           FROM `ff_20_curated.fct_response`
                           GROUP BY 1,2 HAVING COUNTIF(is_primary_run) != 1)), 0
  UNION ALL SELECT 'DQ14', 'income_high < income_low',
    (SELECT COUNTIF(income_high_usd < income_low_usd)
     FROM `ff_20_curated.dim_archetype`), 0
  UNION ALL SELECT 'DQ15', 'replicate rows (n_runs = 2)',
    (SELECT COUNTIF(n_runs_for_question = 2) FROM `ff_20_curated.fct_response`), 7920
  UNION ALL SELECT 'DQ15b', 'replicate keys',
    (SELECT COUNT(*) FROM (SELECT archetype_id, question_key
                           FROM `ff_20_curated.fct_response`
                           GROUP BY 1,2 HAVING COUNT(*) = 2)), 3960
  UNION ALL SELECT 'DQ16', 'dim_run rows',
    (SELECT COUNT(*) FROM `ff_20_curated.dim_run`), 12
  UNION ALL SELECT 'DQ16b', 'dim_run SUM(n_rows)',
    (SELECT CAST(SUM(n_rows) AS INT64) FROM `ff_20_curated.dim_run`), 1392
  UNION ALL SELECT 'GATE4', 'distinct (persona, question) keys',
    (SELECT COUNT(*) FROM (SELECT DISTINCT archetype_id, question_key
                           FROM `ff_20_curated.fct_response`)), 36218
  UNION ALL SELECT 'GATE4b', 'primary rows',
    (SELECT COUNTIF(is_primary_run) FROM `ff_20_curated.fct_response`), 36218
)
SELECT id, check_name, got, want,
       IF(got = want, 'PASS', '*** FAIL ***') AS status
FROM checks
ORDER BY id;
