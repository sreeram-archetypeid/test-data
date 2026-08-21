-- The analysis contract: one row per persona x question x run (40,178).
-- Not date-partitioned on purpose: at ~40k rows partitioning would cost more
-- than it saves. Clustered to match actual query shape.
CREATE OR REPLACE TABLE `ff_20_curated.fct_response`
CLUSTER BY modality, creative, meta, cohort_code AS
WITH joined AS (
  SELECT
    s.*, a.creative, a.cohort_code, a.modality,
    -- Where a persona has two runs of a section, the standalone (non-combined)
    -- file wins. Deterministic, and a no-op for single-run personas.
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
  (SELECT MIN(o.option_code) FROM UNNEST(j.selected_options) o
   WHERE o.option_code < 90) AS primary_code,
  d.scale_max,
  q.is_multi_select
FROM joined j
LEFT JOIN (SELECT DISTINCT question_key, scale_max
           FROM `ff_20_curated.dim_question_option`) d USING (question_key)
LEFT JOIN `ff_20_curated.dim_question` q USING (question_key);
