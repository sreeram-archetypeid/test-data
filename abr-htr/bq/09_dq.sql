-- ============================================================================
-- Stage 9: the data-quality gate. Run it after every load and every rebuild.
-- ============================================================================
-- Two kinds of check here, and the second kind is the unusual one:
--
--  A. STRUCTURAL assertions -- things that must be true of any export.
--  B. PARITY anchors -- specific numbers this pipeline already produced from
--     the same three files when run outside BigQuery. If BigQuery disagrees with
--     them, the SQL is wrong, not the data. That is how this SQL gets tested
--     without waiting for someone to eyeball a banner.
--
-- Delete section B when the source files change; keep section A forever.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- A. structural
-- ---------------------------------------------------------------------------

-- every registered run landed exactly the rows it should have
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT r.run_id
    FROM `PROJECT_ID.abr_20_curated.dim_run` r
    LEFT JOIN (SELECT run_id, COUNT(*) AS n
               FROM `PROJECT_ID.abr_10_staging.stg_response` GROUP BY run_id) s
      USING (run_id)
    WHERE IFNULL(s.n, 0) != r.expected_fact_rows
  )
) = 0 AS 'a run landed a different number of fact rows than personas x questions';

-- archetype_id is the join key for every stage; it must be unique within a run
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT run_id, archetype_id FROM `PROJECT_ID.abr_20_curated.dim_archetype_raw`
    GROUP BY run_id, archetype_id HAVING COUNT(*) > 1
  )
) = 0 AS 'archetype_id is not unique within a run';

-- A persona appearing in two runs of the SAME panel means the exports are not
-- independent generations, and every version delta becomes meaningless.
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT a.panel, a.archetype_id
    FROM `PROJECT_ID.abr_20_curated.dim_archetype` a
    GROUP BY a.panel, a.archetype_id
    HAVING COUNT(DISTINCT a.run_id) > 1
  )
) = 0 AS 'a persona id appears in more than one run of the same panel';

-- question identity must be unique within a run (duplicates get a _dN suffix)
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT run_id, question_key FROM `PROJECT_ID.abr_20_curated.dim_question`
    GROUP BY run_id, question_key HAVING COUNT(*) > 1
  )
) = 0 AS 'question_key collides within a run';

-- no fact without a question
ASSERT (
  SELECT COUNT(*) FROM `PROJECT_ID.abr_20_curated.fct_response` f
  LEFT JOIN `PROJECT_ID.abr_20_curated.dim_question` q USING (run_id, question_key)
  WHERE q.question_key IS NULL
) = 0 AS 'fct_response has a question_key with no dim_question row';

-- ranks must be a dense 1..scale_max with no gaps, per question
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT run_id, question_key,
           MAX(favourability_rank) AS mx,
           COUNT(DISTINCT favourability_rank) AS n
    FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled`
    WHERE favourability_rank IS NOT NULL
    GROUP BY run_id, question_key
    HAVING mx != n
  )
) = 0 AS 'favourability rank is not a dense 1..n within some question';

-- latent favourability must fall as rank rises, within every question
ASSERT (
  SELECT COUNT(*) FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled` a
  JOIN `PROJECT_ID.abr_20_curated.dim_question_option_scaled` b
    USING (run_id, question_key)
  WHERE a.favourability_rank < b.favourability_rank
    AND a.latent_favourability <= b.latent_favourability
) = 0 AS 'latent favourability is not monotonic in rank';

-- a sentinel must never carry a box flag or a latent score
ASSERT (
  SELECT COUNTIF(is_sentinel AND (is_top_box OR latent_favourability IS NOT NULL))
  FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled`
) = 0 AS 'a sentinel option was included in the box maths';

-- a 2-point scale has no top-2 box
ASSERT (
  SELECT COUNTIF(scale_points < 3 AND top2_box_pct IS NOT NULL)
  FROM `PROJECT_ID.abr_30_marts.banner`
) = 0 AS 'top-2 box reported on a scale with fewer than 3 points';

-- ---------------------------------------------------------------------------
-- B. parity anchors -- measured outside BigQuery from the same files.
--    A failure here means this SQL diverged from the reference implementation.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.dq_parity` AS
WITH expected AS (
  SELECT * FROM UNNEST([
    STRUCT('htr_main_42p_0_0_09_01' AS run_id, 'personas' AS metric, 273.0 AS want),
    ('htr_main_42p_0_0_09_01', 'questions', 83.0),
    ('htr_main_42p_0_0_09_01', 'fact_rows', 22659.0),
    ('htr_k3_42p_0_0_09_01', 'personas', 25.0),
    ('htr_k3_42p_0_0_09_01', 'questions', 36.0),
    ('htr_k3_42p_0_0_09_01', 'fact_rows', 900.0),
    ('htr_k9_42p_0_0_09_01', 'personas', 125.0),
    ('htr_k9_42p_0_0_09_01', 'questions', 40.0),
    ('htr_k9_42p_0_0_09_01', 'fact_rows', 5000.0),
    ('htr_k9_42p_0_0_09_01', 'KPLIKE2_top_box_pct', 64.8),
    ('htr_k9_42p_0_0_09_01', 'KPLIKE2_latent_mean', 86.8),
    ('htr_k9_42p_0_0_09_01', 'KPFEEL_top_box_pct', 76.8),
    ('htr_k3_42p_0_0_09_01', 'KPLIKE_top_box_pct', 84.0),
    ('htr_main_42p_0_0_09_01', 'CCOMFORT_top_box_pct', 90.1),
    ('htr_main_42p_0_0_09_01', 'POSTAPPEAL_prose_top_box_pct', 76.1),
    ('htr_main_42p_0_0_09_01', 'DTHEAT_prose_top_box_pct', 56.5),
    ('htr_k3_42p_0_0_09_01', 'SCARY_CLOWN_dislikes_pct', 88.0),
    ('htr_k9_42p_0_0_09_01', 'SCARY_CLOWN_dislikes_pct', 59.2),
    ('htr_main_42p_0_0_09_01', 'SCARY_CLOWN_dislikes_pct', 42.9)
  ])
),
actual AS (
  SELECT run_id, 'personas' AS metric, CAST(n_personas AS FLOAT64) AS got
  FROM `PROJECT_ID.abr_20_curated.dim_run`
  UNION ALL SELECT run_id, 'questions', CAST(n_questions AS FLOAT64)
  FROM `PROJECT_ID.abr_20_curated.dim_run`
  UNION ALL SELECT run_id, 'fact_rows', CAST(COUNT(*) AS FLOAT64)
  FROM `PROJECT_ID.abr_10_staging.stg_response` GROUP BY run_id
  UNION ALL SELECT run_id, CONCAT(meta, '_top_box_pct'), top_box_pct
  FROM `PROJECT_ID.abr_30_marts.banner`
  WHERE cut = 'total' AND meta IN ('KPLIKE2', 'KPLIKE', 'KPFEEL', 'CCOMFORT')
  UNION ALL SELECT run_id, CONCAT(meta, '_latent_mean'), latent_mean
  FROM `PROJECT_ID.abr_30_marts.banner`
  WHERE cut = 'total' AND meta = 'KPLIKE2'
  UNION ALL SELECT run_id, CONCAT(meta, '_prose_top_box_pct'), top_box_pct
  FROM `PROJECT_ID.abr_30_marts.prose_metric_summary`
  WHERE meta IN ('POSTAPPEAL', 'DTHEAT')
  UNION ALL SELECT run_id, CONCAT(theme_id, '_dislikes_pct'), pct
  FROM `PROJECT_ID.abr_30_marts.theme_by_cut`
  WHERE role = 'dislikes' AND cut = 'total' AND theme_id = 'SCARY_CLOWN'
)
SELECT e.run_id, e.metric, e.want, a.got,
       ROUND(IFNULL(a.got, -1) - e.want, 2) AS diff,
       IF(a.got IS NOT NULL AND ABS(a.got - e.want) <= 0.15, 'MATCH', 'MISMATCH') AS status
FROM expected e
LEFT JOIN actual a USING (run_id, metric)
ORDER BY status DESC, e.run_id, e.metric;

-- Look at the table above before trusting anything downstream. Then enforce it:
ASSERT (
  SELECT COUNTIF(status = 'MISMATCH') FROM `PROJECT_ID.abr_30_marts.dq_parity`
) = 0 AS 'BigQuery output diverges from the reference implementation -- see abr_30_marts.dq_parity';
