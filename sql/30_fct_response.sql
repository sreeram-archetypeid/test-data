-- fct_response: the analysis contract. One row per (persona, run, question).
-- Expected 40,178 rows.
--
-- This is the table analysts and models bind to. Everything upstream of it is
-- implementation detail; everything downstream reads only from here and the
-- dimensions.
--
-- The replicate resolution
-- -----------------------
-- Section 2.1 was run twice for cohorts G.2 and S.1 -- same personas, same 20
-- questions, different answers. Nothing is deduplicated, so the grain includes
-- run_id and 3,960 (persona, question) keys carry two rows each.
--
-- is_primary_run picks one row per (persona, question) deterministically: the
-- standalone file beats the combined 2.1X file. For the 32,258 single-run keys
-- it is a no-op. Any query crossing sections MUST filter on it, or it
-- double-counts 198 personas.
--
--   ORDER BY ENDS_WITH(run_id, 'x')  ->  FALSE (0) sorts first  ->  standalone wins
--
-- Note this is the one modelling choice still awaiting research-lead
-- confirmation (Appendix A item 5): if the standalone 2.1 files turn out to be
-- discarded pilots rather than valid replicates, the ORDER BY flips. Everything
-- else is unaffected, which is why the rule lives in exactly one place.
--
-- primary_code
-- ------------
-- The lowest non-sentinel option code on the row. Sentinels (>= 90, i.e.
-- '99. None of the above') are excluded per D9 -- which only works because
-- option_code is read from the code prefix rather than the position prefix
-- (F5).
--
-- It is NULL on 5,587 rows: the 4,574 open-ends and 596 numeric ratings have no
-- selections at all, plus 417 rows where the respondent's only selection WAS a
-- sentinel. That last group is a real answer ("none of these"), not missing
-- data -- treat it as such downstream.
--
-- Physical layout
-- ---------------
-- Clustered, never date-partitioned. 40,178 rows is four orders of magnitude
-- below where partitioning earns anything; partitions of a few hundred rows
-- would scan and cost more. Cluster order matches real query shape: modality
-- and creative filter first, then question, then cut.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.fct_response`
CLUSTER BY modality, creative, meta, cohort_code AS
WITH scale AS (
  SELECT DISTINCT question_key, scale_max
  FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`
),
joined AS (
  SELECT
    s.*,
    a.modality,
    a.creative,
    a.cohort_code,
    ROW_NUMBER() OVER (
      PARTITION BY s.archetype_id, s.question_key
      ORDER BY ENDS_WITH(s.run_id, 'x') ASC, s.run_id ASC
    ) AS run_rank,
    COUNT(*) OVER (
      PARTITION BY s.archetype_id, s.question_key
    ) AS run_count
  FROM `${PROJECT_ID}.${DS_STG}.stg_response` AS s
  JOIN `${PROJECT_ID}.${DS_CUR}.dim_archetype` AS a
    USING (archetype_id)
)
SELECT
  j.* EXCEPT (run_rank, run_count),
  (j.run_rank = 1) AS is_primary_run,
  j.run_count      AS n_runs_for_question,
  (
    SELECT MIN(o.option_code)
    FROM UNNEST(j.selected_options) AS o
    WHERE o.option_code < 90
  ) AS primary_code,
  sc.scale_max
FROM joined AS j
LEFT JOIN scale AS sc
  ON sc.question_key = j.question_key;
