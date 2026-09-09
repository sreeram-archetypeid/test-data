-- ============================================================================
-- Stage 7: score the prose-only headline metrics.
-- ============================================================================
-- Ten of the adult panel's headline metrics have no closed-end at all. Appeal,
-- appeal to a child, likelihood a child asks to see it, recommend (parent and
-- non-parent path), theatrical intent, streaming intent and category interest
-- all arrive as sentences. Until they are scored they cannot appear in a banner,
-- and they are the numbers a distributor actually cares about.
--
-- This is a deterministic BASELINE against abr_00_config.prose_cue. It is not a
-- replacement for the AI pass in 11_ai_prose_score.sql -- it is what makes that
-- pass checkable, because you know the expected distribution before you spend a
-- single call.
--
-- It also cross-checks itself against the aat_* block, which carries the
-- generator's own view of some of the same constructs. Two independent readings
-- of one persona agreeing is evidence; disagreeing is a finding.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.prose_score`
CLUSTER BY run_id, meta AS
WITH target AS (
  SELECT f.run_id, f.panel, f.build, f.archetype_id, f.question_key, f.meta,
         q.question_text, f.qual_clean, m.family
  FROM `PROJECT_ID.abr_20_curated.fct_response` f
  JOIN `PROJECT_ID.abr_20_curated.dim_question` q USING (run_id, question_key)
  JOIN `PROJECT_ID.abr_00_config.prose_metric` m ON m.meta = f.meta
  WHERE q.channel = 'open_end' AND COALESCE(f.qual_clean, '') != ''
    AND NOT f.is_harness_leak
),
flagged AS (
  SELECT t.*,
    -- A persona writing "N/A - I am a parent" is correcting a base the harness
    -- got wrong by forcing everyone down both the parent and non-parent paths.
    -- Counted separately from unscored: it is evidence, not a failure to read.
    REGEXP_CONTAINS(LOWER(t.qual_clean),
      (SELECT pattern FROM `PROJECT_ID.abr_00_config.prose_not_applicable`))
      AS is_not_applicable
  FROM target t
),
matches AS (
  SELECT
    f.run_id, f.archetype_id, f.meta, f.family, f.question_key,
    c.pattern, c.score AS cue_score,
    REGEXP_EXTRACT(LOWER(f.qual_clean), c.pattern) AS matched_text,
    -- a negation just before the cue flips it: "not very likely" is a 2, not a 5.
    -- 30 characters is the SQL stand-in for the local scorer's four-word window.
    EXISTS (
      SELECT 1 FROM `PROJECT_ID.abr_00_config.prose_negation` n
      WHERE STRPOS(
              SUBSTR(LOWER(f.qual_clean),
                     GREATEST(1, STRPOS(LOWER(f.qual_clean),
                              REGEXP_EXTRACT(LOWER(f.qual_clean), c.pattern)) - 30),
                     30),
              n.token) > 0
    ) AS negated
  FROM flagged f
  JOIN `PROJECT_ID.abr_00_config.prose_cue` c
    ON c.family = f.family AND REGEXP_CONTAINS(LOWER(f.qual_clean), c.pattern)
  WHERE NOT f.is_not_applicable
),
resolved AS (
  SELECT
    run_id, archetype_id, meta, family, question_key,
    -- the most extreme cue in the sentence is the most informative one
    ARRAY_AGG(STRUCT(IF(negated, 6 - cue_score, cue_score) AS score,
                     matched_text, negated, pattern)
              ORDER BY ABS(cue_score - 3) DESC LIMIT 1)[OFFSET(0)] AS top,
    COUNT(*) AS n_cues,
    MIN(IF(negated, 6 - cue_score, cue_score)) AS min_score,
    MAX(IF(negated, 6 - cue_score, cue_score)) AS max_score
  FROM matches
  GROUP BY run_id, archetype_id, meta, family, question_key
)
SELECT
  f.run_id, f.panel, f.build, f.archetype_id, f.meta, f.family,
  SUBSTR(f.question_text, 1, 110) AS question_text,
  r.top.score AS score,
  CASE
    WHEN f.is_not_applicable THEN 'not_applicable'
    WHEN r.top.score IS NULL THEN 'unscored'
    WHEN r.n_cues = 1 THEN 'medium'
    WHEN r.min_score = r.max_score THEN 'high'
    WHEN r.max_score - r.min_score >= 3 THEN 'low'   -- the sentence says two opposite things
    ELSE 'medium'
  END AS confidence,
  FORMAT("'%s'%s%s", IFNULL(r.top.matched_text, ''),
         IF(r.top.negated, ' (negated)', ''),
         IF(r.n_cues > 1, FORMAT(' +%d more cue(s)', r.n_cues - 1), '')) AS evidence,
  LENGTH(f.qual_clean) AS n_chars,
  SUBSTR(f.qual_clean, 1, 300) AS text,
  -- independent second reading, where the aat block has one
  CASE f.meta WHEN 'DTHEAT' THEN a.opening_weekend_intent_rank * 2 - 1
              WHEN 'POSTAPPEAL' THEN a.top_box_category_rank + 1 END AS aat_score,
  CASE f.meta WHEN 'DTHEAT' THEN a.aat_opening_weekend_intent
              WHEN 'POSTAPPEAL' THEN a.aat_top_box_category END AS aat_value
FROM flagged f
LEFT JOIN resolved r USING (run_id, archetype_id, meta, question_key)
LEFT JOIN `PROJECT_ID.abr_20_curated.dim_aat` a
  ON a.run_id = f.run_id AND a.archetype_id = f.archetype_id;

-- One row per metric: distribution, coverage, and how well the two independent
-- readings agree. A metric where they disagree is where the AI pass should be
-- pointed first -- in the current wave that is theatrical intent, not appeal.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.prose_metric_summary` AS
SELECT
  run_id, panel, meta, family,
  COUNTIF(confidence != 'not_applicable') AS base,
  COUNTIF(score IS NOT NULL) AS scored,
  COUNTIF(confidence = 'not_applicable') AS not_applicable,
  COUNTIF(confidence = 'unscored') AS unscored,
  COUNTIF(confidence = 'low') AS low_confidence,
  ROUND(100.0 * COUNTIF(score = 5) / NULLIF(COUNTIF(score IS NOT NULL), 0), 1) AS top_box_pct,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_low`(
    COUNTIF(score = 5), COUNTIF(score IS NOT NULL)), 1) AS tb_ci_low,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_high`(
    COUNTIF(score = 5), COUNTIF(score IS NOT NULL)), 1) AS tb_ci_high,
  ROUND(100.0 * COUNTIF(score >= 4) / NULLIF(COUNTIF(score IS NOT NULL), 0), 1) AS top2_box_pct,
  ROUND(AVG(score), 2) AS mean_score,
  ROUND(100.0 * COUNTIF(aat_score IS NOT NULL AND ABS(score - aat_score) <= 1)
        / NULLIF(COUNTIF(aat_score IS NOT NULL AND score IS NOT NULL), 0), 1)
    AS aat_agreement_pct,
  COUNTIF(aat_score IS NOT NULL AND score IS NOT NULL) AS aat_agreement_base
FROM `PROJECT_ID.abr_30_marts.prose_score`
GROUP BY run_id, panel, meta, family;
