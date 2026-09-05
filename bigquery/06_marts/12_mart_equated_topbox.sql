-- ============================================================================
-- STAGE 6a — EQUATED TOP-BOX MART   (what you actually report)
--
-- Produces, for every closed-end construct:
--   raw_tb / raw_t2b / raw_bb   correct WITHIN an instrument, never across
--   latent_mean                 scale-invariant, comparable across instruments
--   eq_tb / eq_t2b / eq_bb      equated at a common latent threshold
--   Wilson 95% CI               honest about n=43
--
-- WHY equated boxes as well as raw: raw top box answers "how many picked the
-- best option we offered them", which is a fact about the questionnaire as much
-- as about the audience. Equated top box answers "how many were above this
-- level of enthusiasm", which is a fact about the audience only. Report raw
-- within an instrument; use equated whenever you compare across them.
--
-- WHY Wilson and not the normal approximation: at n=43 with p near 0.98, the
-- normal interval runs past 100% and is simply wrong. Several headline numbers
-- in this study sit exactly there. Wilson stays inside [0,1] and behaves at
-- small n. It is a few lines of arithmetic and it is the difference between a
-- defensible number and a wrong one.
--
-- THRESHOLDS: eq_tb at latent >= 80, eq_t2b at >= 60, eq_bb at <= 30. These are
-- the tunable knobs. Calibrate them ONCE (see 6a.3) and then leave them alone —
-- moving a threshold after seeing results is how you fool yourself.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_marts.mart_topbox` AS
WITH scored AS (
  SELECT
    f.instrument, f.age_band_x AS age_band, f.question_key, f.question_text,
    f.archetype_id, m.latent_score, m.rank_position, m.n_options,
    m.is_raw_top_box, m.is_raw_top2_box, m.is_raw_bottom_box
  FROM (
    SELECT f.*, a.age_band AS age_band_x
    FROM `PROJECT_ID.abr_20_curated.fct_response` f
    JOIN `PROJECT_ID.abr_20_curated.dim_archetype` a USING (archetype_id)
  ) f
  JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
    ON f.instrument = m.instrument
   AND f.question_key = m.question_key
   AND f.selected_norm = m.option_norm
  WHERE f.question_type = 'single_select'
    AND f.is_base_eligible          -- keeps Q28/Q29 off the full base
),
agg AS (
  SELECT
    instrument, age_band, question_key, ANY_VALUE(question_text) AS question_text,
    COUNT(*)                                    AS base_n,
    ANY_VALUE(n_options)                        AS scale_points,
    AVG(latent_score)                           AS latent_mean,
    STDDEV(latent_score)                        AS latent_sd,
    COUNTIF(is_raw_top_box)    / COUNT(*)       AS raw_tb,
    COUNTIF(is_raw_top2_box)   / COUNT(*)       AS raw_t2b,
    COUNTIF(is_raw_bottom_box) / COUNT(*)       AS raw_bb,
    COUNTIF(latent_score >= 80) / COUNT(*)      AS eq_tb,
    COUNTIF(latent_score >= 60) / COUNT(*)      AS eq_t2b,
    COUNTIF(latent_score <= 30) / COUNT(*)      AS eq_bb,
    COUNTIF(latent_score >= 60)                 AS eq_t2b_count
  FROM scored
  GROUP BY instrument, age_band, question_key
)
SELECT
  * EXCEPT(eq_t2b_count),
  -- Wilson score interval on the equated T2B, z = 1.96.
  -- centre = (p + z^2/2n) / (1 + z^2/n)
  -- half   = z/(1+z^2/n) * sqrt( p(1-p)/n + z^2/4n^2 )
  ROUND(GREATEST(0,
    ((eq_t2b + 1.96*1.96/(2*base_n)) / (1 + 1.96*1.96/base_n))
    - (1.96/(1 + 1.96*1.96/base_n))
      * SQRT(eq_t2b*(1-eq_t2b)/base_n + 1.96*1.96/(4*base_n*base_n))
  ), 4) AS eq_t2b_ci_low,
  ROUND(LEAST(1,
    ((eq_t2b + 1.96*1.96/(2*base_n)) / (1 + 1.96*1.96/base_n))
    + (1.96/(1 + 1.96*1.96/base_n))
      * SQRT(eq_t2b*(1-eq_t2b)/base_n + 1.96*1.96/(4*base_n*base_n))
  ), 4) AS eq_t2b_ci_high,
  -- Reporting guard. n=43 and n=109 are the ONLY bases that clear 30 here;
  -- every demographic subcut falls below it. The flag travels with the number
  -- so it cannot be dropped in a copy-paste into a deck.
  CASE WHEN base_n >= 100 THEN 'reportable'
       WHEN base_n >= 30  THEN 'low base — caution'
       ELSE 'DO NOT REPORT — base under 30' END AS base_flag,
  CURRENT_TIMESTAMP() AS built_at
FROM agg;


-- ---- 6a.2  Cross-instrument comparison, done correctly ---------------------
-- The 24 identically-worded questions, compared on the equated axis.
-- Compare THIS, never raw_tb across instruments.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_marts.v_age_band_compare` AS
SELECT
  t1.question_text,
  t1.scale_points AS t1_scale_pts, t23.scale_points AS t23_scale_pts,
  t1.base_n AS n_4_7,  ROUND(t1.eq_t2b*100,1)  AS eq_t2b_4_7,
  t23.base_n AS n_8_12, ROUND(t23.eq_t2b*100,1) AS eq_t2b_8_12,
  ROUND((t23.eq_t2b - t1.eq_t2b)*100, 1)        AS equated_gap_pts,
  -- The naive comparison, shown alongside purely to demonstrate the damage.
  ROUND((t23.raw_tb - t1.raw_tb)*100, 1)        AS naive_raw_tb_gap_pts,
  -- Overlapping Wilson intervals mean the gap is not distinguishable from noise.
  IF(t1.eq_t2b_ci_low <= t23.eq_t2b_ci_high
     AND t23.eq_t2b_ci_low <= t1.eq_t2b_ci_high,
     'CIs overlap — not a real difference',
     'CIs separate — worth reporting')          AS significance_read
FROM `PROJECT_ID.abr_40_marts.mart_topbox` t1
JOIN `PROJECT_ID.abr_40_marts.mart_topbox` t23
  ON t1.question_text = t23.question_text
 AND t1.instrument = 'T1' AND t23.instrument = 'T23';


-- ---- 6a.3  Threshold calibration (run ONCE, then freeze) -------------------
-- Sweeps the equating threshold and shows how each construct responds. Pick the
-- threshold where equated T2B best reproduces the hand-collapsed values already
-- established (appeal 84/84, advocacy 65/65, comprehension 95/100), then write
-- it into 6a.1 and never touch it again.
--
-- WHY freeze: a threshold tuned per-question, after seeing the answer, is not a
-- measurement — it is a way to get whatever number you wanted.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_threshold_sweep` AS
SELECT
  th,
  instrument,
  question_text,
  ROUND(COUNTIF(latent_score >= th) / COUNT(*) * 100, 1) AS pct_above
FROM (
  SELECT f.instrument, f.question_text, m.latent_score
  FROM `PROJECT_ID.abr_20_curated.fct_response` f
  JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
    ON f.instrument=m.instrument AND f.question_key=m.question_key
   AND f.selected_norm=m.option_norm
  WHERE f.question_type='single_select' AND f.is_base_eligible
), UNNEST([50,55,60,65,70,75,80,85]) AS th
GROUP BY th, instrument, question_text
ORDER BY question_text, instrument, th;
