-- ============================================================================
-- STAGE 5b — VALIDATE THE SCALE MAP BEFORE USING IT
--
-- WHY this file exists: Stage 5a's output is not data, it is a MEASUREMENT
-- INSTRUMENT. Every top-box number in the study is computed through it. An
-- unvalidated ranking that quietly puts "It was okay" above "I liked it" would
-- corrupt every downstream figure while looking perfectly plausible.
--
-- Four checks. All must pass before Stage 6.
-- ============================================================================

-- ---- V1  Score/option count parity -----------------------------------------
-- The prompt demanded one score per option. A mismatch means the model
-- truncated, and the ranking is unusable for that question.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_scale_check_parity` AS
SELECT instrument, question_key, n_options,
       ARRAY_LENGTH(SPLIT(ranked_options,'|')) AS n_ranked,
       ARRAY_LENGTH(SPLIT(scores,'|'))         AS n_scores,
       IF(n_options = ARRAY_LENGTH(SPLIT(ranked_options,'|'))
          AND n_options = ARRAY_LENGTH(SPLIT(scores,'|')), 'PASS','FAIL') AS verdict
FROM `PROJECT_ID.abr_30_semantic.option_rank_raw`
WHERE is_ordinal;

-- ---- V2  Strict monotonicity ------------------------------------------------
-- Scores must decrease as rank increases. A non-monotonic sequence means the
-- model's ranking and its scoring disagree with each other.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_scale_check_monotonic` AS
SELECT instrument, question_key,
       COUNTIF(latent_score >= prev_score) AS violations,
       IF(COUNTIF(latent_score >= prev_score) = 0, 'PASS','FAIL') AS verdict
FROM (
  SELECT instrument, question_key, rank_position, latent_score,
         LAG(latent_score) OVER (PARTITION BY instrument, question_key
                                 ORDER BY rank_position) AS prev_score
  FROM `PROJECT_ID.abr_30_semantic.option_scale_map`
)
WHERE prev_score IS NOT NULL
GROUP BY instrument, question_key;

-- ---- V3  Every observed label got scored ------------------------------------
-- If a label respondents actually chose is missing from the map, its responses
-- silently vanish from every top-box calculation.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_scale_check_coverage` AS
SELECT o.instrument, o.question_key, o.option_label, o.n_selected,
       IF(m.option_norm IS NULL, 'FAIL — unscored label','PASS') AS verdict
FROM `PROJECT_ID.abr_20_curated.dim_question_option` o
LEFT JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
  ON o.instrument = m.instrument AND o.question_key = m.question_key
 AND o.option_norm = m.option_norm
WHERE o.question_type = 'single_select';

-- ---- V4  Cross-instrument coherence  ** the one that matters ** -------------
-- The 24 questions worded IDENTICALLY in both files measure the same construct
-- on different scales. If the equating worked, their WEIGHTED MEAN latent
-- scores should land close together — that is the whole claim being made.
--
-- Read this as a diagnostic, not a pass/fail: a genuine age difference (title
-- liking, theatrical intent) SHOULD show a gap. What would indict the method is
-- a large gap on constructs that were already shown to be stable once collapsed
-- by hand (appeal, advocacy, comprehension). Those three are the ones to read.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_scale_check_coherence` AS
WITH scored AS (
  SELECT f.instrument, f.question_key, f.question_text, m.latent_score
  FROM `PROJECT_ID.abr_20_curated.fct_response` f
  JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
    ON f.instrument = m.instrument AND f.question_key = m.question_key
   AND f.selected_norm = m.option_norm
  WHERE f.question_type = 'single_select' AND f.is_base_eligible
),
by_q AS (
  SELECT question_text, instrument,
         COUNT(*) AS n, ROUND(AVG(latent_score),1) AS mean_latent
  FROM scored GROUP BY 1,2
)
SELECT
  a.question_text,
  a.n AS n_t1,  a.mean_latent AS latent_t1,
  b.n AS n_t23, b.mean_latent AS latent_t23,
  ROUND(b.mean_latent - a.mean_latent, 1) AS latent_gap,
  CASE WHEN ABS(b.mean_latent - a.mean_latent) <= 10 THEN 'coherent'
       WHEN ABS(b.mean_latent - a.mean_latent) <= 20 THEN 'review'
       ELSE 'INVESTIGATE' END AS verdict
FROM by_q a JOIN by_q b
  ON a.question_text = b.question_text AND a.instrument='T1' AND b.instrument='T23';

-- ---- V5  Re-run stability ---------------------------------------------------
-- Run Stage 5a a SECOND time into option_rank_raw_run2, then run this.
-- Even at temperature 0 the endpoint is not guaranteed byte-identical. If the
-- ranking is not stable, no confidence interval downstream is meaningful.
--
--   CREATE TABLE abr_30_semantic.option_rank_raw_run2 AS (re-run 5a.2 body)
--
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_scale_check_stability` AS
SELECT a.instrument, a.question_key,
       a.ranked_options AS run1, b.ranked_options AS run2,
       IF(a.ranked_options = b.ranked_options, 'STABLE','DRIFTED') AS verdict
FROM `PROJECT_ID.abr_30_semantic.option_rank_raw` a
JOIN `PROJECT_ID.abr_30_semantic.option_rank_raw_run2` b
  USING (instrument, question_key);

-- ---- THE GATE ---------------------------------------------------------------
SELECT 'parity'    AS check, COUNTIF(verdict!='PASS') AS failures FROM `PROJECT_ID.abr_90_ops.v_scale_check_parity`
UNION ALL SELECT 'monotonic',  COUNTIF(verdict!='PASS') FROM `PROJECT_ID.abr_90_ops.v_scale_check_monotonic`
UNION ALL SELECT 'coverage',   COUNTIF(verdict!='PASS') FROM `PROJECT_ID.abr_90_ops.v_scale_check_coverage`
UNION ALL SELECT 'coherence',  COUNTIF(verdict='INVESTIGATE') FROM `PROJECT_ID.abr_90_ops.v_scale_check_coherence`;
