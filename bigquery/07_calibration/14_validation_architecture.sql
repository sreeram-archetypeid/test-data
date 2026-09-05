-- ============================================================================
-- STAGE 9 — VALIDATION ARCHITECTURE
--            (the Vancouver mindset, applied to data with no human anchor)
--
-- Vancouver could validate against humans. This study cannot — there is no
-- human trailer test. But Vancouver's method was never only "hit 59.5%". Its
-- gates were largely STRUCTURAL:
--
--     "same character rank-order (Buddy #1) … pacing as softest element …
--      the '~99%' quoted in the meeting was in-room enthusiasm, not the
--      survey number."
--
-- Structural claims can be validated WITHOUT a human anchor. That is what this
-- stage does, using the asset Vancouver did not have: two independently
-- generated cohorts (T1 n=43, T23 n=109) answering 24 IDENTICALLY-WORDED
-- questions. That is a natural replication experiment.
--
-- THE RULE: declare the gates in 9.0 and record them BEFORE running 9.1-9.5.
-- A threshold chosen after seeing the result is not a test.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

-- ---- 9.0  PRE-REGISTER THE GATES -------------------------------------------
-- Fill in `predicted` yourself, before running anything below. This is the
-- discipline Vancouver's Calibration Benchmarks tab encodes, and the single
-- cheapest thing in this whole plan.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_90_ops.prereg_gates` (
  gate_id      STRING,
  gate_type    STRING,   -- 'replication' | 'rank_order' | 'known_answer' | 'stability' | 'plausibility'
  claim        STRING,
  predicted    STRING,
  tolerance    STRING,
  rationale    STRING,
  registered_at TIMESTAMP
);

INSERT INTO `PROJECT_ID.abr_90_ops.prereg_gates` VALUES
 ('G1','replication','Appeal (Q7/Q8) equated T2B agrees across the two cohorts',
  'gap <= 10 pts','10 pts',
  'Two independent cohorts, identical wording. A large gap means generation variance, not age.',
  CURRENT_TIMESTAMP()),
 ('G2','rank_order','Liked-elements rank order holds across cohorts',
  'Sport and Main character rank 1-2 in both','top-2 set identical',
  'Vancouver''s Buddy-#1 test. Rank order is validatable without a human anchor.',
  CURRENT_TIMESTAMP()),
 ('G3','rank_order','Sensory/audio is the #1 volunteered dislike in both cohorts',
  'rank 1 in both','rank 1',
  'The study''s key finding. If it does not replicate across cohorts, do not brief on it.',
  CURRENT_TIMESTAMP()),
 ('G4','known_answer','Factual recall accuracy is high in both cohorts',
  'title recall >= 80%, window recall >= 90%','n/a',
  'Ground truth exists for Q50 and Q37. The only externally checkable accuracy in the study.',
  CURRENT_TIMESTAMP()),
 ('G5','stability','Re-running generation reproduces headline equated T2B',
  'within 5 pts across runs','5 pts',
  'Nothing here is a replicate, so generation variance is currently UNMEASURED.',
  CURRENT_TIMESTAMP()),
 ('G6','plausibility','Headline T2B sits inside the range real kids produce',
  'between 55% and 90%','soft band',
  'Vancouver kids CQ1 T2B was 78.4% on the FULL FILM. Different stimulus, so NOT a target — '
  'but a synthetic panel returning 99% would be outside anything humans produced for this franchise.',
  CURRENT_TIMESTAMP());


-- ---- 9.1  G1 — CROSS-COHORT REPLICATION  (the substitute for calibration) --
-- The 24 identically-worded questions, on the equated axis, with the Wilson
-- overlap test. This is the closest thing to external validation available.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_gate_replication` AS
SELECT
  question_text,
  n_4_7, eq_t2b_4_7, n_8_12, eq_t2b_8_12,
  equated_gap_pts,
  significance_read,
  IF(ABS(equated_gap_pts) <= 10, 'PASS','FAIL') AS g1_verdict
FROM `PROJECT_ID.abr_40_marts.v_age_band_compare`;

-- Headline read: how many of the 24 shared constructs replicate?
SELECT COUNTIF(g1_verdict='PASS') AS replicated,
       COUNT(*) AS shared_constructs,
       ROUND(COUNTIF(g1_verdict='PASS')/COUNT(*)*100,1) AS pct_replicating
FROM `PROJECT_ID.abr_90_ops.v_gate_replication`;


-- ---- 9.2  G2/G3 — RANK-ORDER INVARIANTS ------------------------------------
-- Vancouver's strongest idea. Levels need an anchor; ORDER does not. If the
-- same elements rank 1-2 in two independent cohorts, that ordering is a finding
-- you can brief even though you cannot validate the absolute percentages.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_gate_rank_order` AS
WITH liked AS (
  SELECT f.instrument, TRIM(opt) AS element, COUNT(*) AS n,
         COUNT(*) / COUNT(DISTINCT f.archetype_id)
           OVER (PARTITION BY f.instrument) AS pct
  FROM `PROJECT_ID.abr_20_curated.fct_response` f,
       UNNEST(SPLIT(f.selected_raw,'|')) AS opt
  WHERE f.question_key = 'Q33' AND f.selected_raw IS NOT NULL
  GROUP BY f.instrument, element, f.archetype_id
),
ranked AS (
  SELECT instrument, element, SUM(n) AS mentions,
         RANK() OVER (PARTITION BY instrument ORDER BY SUM(n) DESC) AS rnk
  FROM liked GROUP BY instrument, element
)
SELECT a.element,
       a.rnk AS rank_4_7, b.rnk AS rank_8_12,
       ABS(a.rnk - b.rnk) AS rank_shift,
       IF(a.rnk <= 2 AND b.rnk <= 2, 'top-2 in both',
          IF(ABS(a.rnk-b.rnk) <= 1, 'stable', 'MOVED')) AS g2_verdict
FROM ranked a JOIN ranked b
  ON a.element = b.element AND a.instrument='T1' AND b.instrument='T23'
ORDER BY a.rnk;

-- G3: does the sensory complaint rank #1 among dislikes in BOTH cohorts?
-- Uses the Stage 5c codes, so it tests the coded finding, not a regex.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_gate_dislike_rank` AS
SELECT instrument, primary_theme,
       COUNT(*) AS n,
       RANK() OVER (PARTITION BY instrument ORDER BY COUNT(*) DESC) AS rnk
FROM `PROJECT_ID.abr_30_semantic.verbatim_coded`
WHERE question_key = 'Q32' AND sentiment IN ('Negative','Mixed')
GROUP BY instrument, primary_theme
ORDER BY instrument, rnk;


-- ---- 9.3  G4 — KNOWN-ANSWER SCORING ----------------------------------------
-- The only place in this study with external ground truth. Vancouver tracked
-- "grandfather reveal / what happened to dad" as themes that must reproduce;
-- this is the same idea with a checkable answer.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_gate_known_answer` AS
SELECT
  f.instrument,
  COUNTIF(f.question_key='Q50'
          AND REGEXP_CONTAINS(LOWER(f.qual_clean), r'air ?bud'))
    / NULLIF(COUNTIF(f.question_key='Q50'),0)                     AS title_recall_acc,
  COUNTIF(f.question_key='Q37' AND f.selected_raw='In a movie theatre')
    / NULLIF(COUNTIF(f.question_key='Q37' AND f.selected_raw IS NOT NULL),0)
                                                                  AS window_recall_acc,
  COUNTIF(f.question_key='Q1'
          AND REGEXP_EXTRACT(f.selected_raw, r'(\d+)') = CAST(a.age AS STRING))
    / NULLIF(COUNTIF(f.question_key='Q1'),0)                      AS age_consistency
FROM `PROJECT_ID.abr_20_curated.fct_response` f
JOIN `PROJECT_ID.abr_20_curated.dim_archetype` a USING (archetype_id)
GROUP BY f.instrument;


-- ---- 9.4  G5 — GENERATION VARIANCE (currently UNMEASURED) ------------------
-- Nothing in these files is a replicate, so no confidence interval that
-- accounts for generation variance is currently defensible. The Wilson CIs in
-- Stage 6 cover SAMPLING variance only.
--
-- To close this: re-generate ~20 personas from the same specs, load them as
-- instrument='T1_RUN2', and run this. It is the cheapest high-value addition
-- to the whole programme.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_90_ops.v_gate_stability` AS
SELECT
  a.question_key,
  ROUND(AVG(a.latent_score),1) AS run1_latent,
  ROUND(AVG(b.latent_score),1) AS run2_latent,
  ROUND(ABS(AVG(a.latent_score)-AVG(b.latent_score)),1) AS drift,
  IF(ABS(AVG(a.latent_score)-AVG(b.latent_score)) <= 5,'PASS','FAIL') AS g5_verdict
FROM (SELECT f.question_key, m.latent_score
      FROM `PROJECT_ID.abr_20_curated.fct_response` f
      JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
        ON f.instrument=m.instrument AND f.question_key=m.question_key
       AND f.selected_norm=m.option_norm
      WHERE f.instrument='T1') a
JOIN (SELECT f.question_key, m.latent_score
      FROM `PROJECT_ID.abr_20_curated.fct_response` f
      JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
        ON f.instrument=m.instrument AND f.question_key=m.question_key
       AND f.selected_norm=m.option_norm
      WHERE f.instrument='T1_RUN2') b
  USING (question_key)
GROUP BY a.question_key;


-- ---- 9.5  G6 — PLAUSIBILITY BAND, NOT A CALIBRATION TARGET -----------------
-- The Vancouver human numbers, stored ONLY as a sanity band.
--
-- READ THIS BEFORE USING THE TABLE: different stimulus (full film vs trailer),
-- different instrument, different population (62% girl, ~52% Asian vs your
-- 50/50, 8.6% Asian). These rows must never be joined to a synthetic result as
-- if they were a target. Their single legitimate use is the outer bound: if a
-- synthetic kids panel returns 99% T2B, Vancouver tells you no real audience
-- for this franchise produced that, and something is wrong upstream.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_90_ops.human_plausibility_band` AS
SELECT * FROM UNNEST([
  STRUCT('kids'   AS cohort, 'CQ1 overall' AS metric, 47.3 AS human_tb,
         78.4 AS human_t2b, 1.78 AS human_mean, 74 AS human_n,
         'full film screening, Vancouver, older study' AS stimulus,
         'plausibility band only — NOT a calibration target' AS usage),
  STRUCT('adults','Q1 overall', 26.2, 59.5, 2.25, 84,
         'full film screening, Vancouver, older study',
         'OUT OF SCOPE — no adult synthetic panel exists'),
  STRUCT('adults','Q2 recommend', 31.0, 86.9, CAST(NULL AS FLOAT64), 84,
         'full film screening, Vancouver, older study',
         'OUT OF SCOPE — no adult synthetic panel exists')
]);

-- The band check. Expect the trailer T2B to sit ABOVE the film number — a
-- trailer is a highlight reel and should out-test the film it advertises.
-- A synthetic result BELOW the film number, or above ~90%, is worth a look.
SELECT
  m.instrument, m.question_text,
  ROUND(m.eq_t2b*100,1) AS synthetic_t2b,
  b.human_t2b           AS vancouver_film_t2b_reference,
  CASE WHEN m.eq_t2b*100 BETWEEN 55 AND 90 THEN 'within plausible range'
       ELSE 'OUTSIDE plausible range — investigate' END AS g6_verdict
FROM `PROJECT_ID.abr_40_marts.mart_topbox` m
CROSS JOIN (SELECT * FROM `PROJECT_ID.abr_90_ops.human_plausibility_band`
            WHERE cohort='kids') b
WHERE m.question_key IN ('Q7','Q8');
