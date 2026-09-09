-- ============================================================================
-- Stage 8: the marts. Banner, cross-panel equating, version comparison,
--          known-answer accuracy, intent drivers.
-- ============================================================================
DECLARE noise_floor FLOAT64 DEFAULT 8.8;
-- Latent points. This is the mean absolute movement measured between two
-- independently generated runs of the SAME instrument on disjoint personas
-- (19 identically-worded constructs, kids 7-12). A build-to-build move smaller
-- than this is indistinguishable from re-running the same build.
--
-- Replace it the moment you have a true replicate pair -- same build, generated
-- twice -- because that is a cleaner floor than a cross-instrument one.
-- mart_run_agreement below reports the empirical floor for every pair it finds.

-- ---------------------------------------------------------------------------
-- The banner. Ordinal favourability questions only; nominal questions are
-- reported as option shares instead, because forcing a rank onto "who would you
-- watch with" invents a scale the questionnaire never asked for.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.banner`
CLUSTER BY run_id, meta AS
WITH resp AS (
  SELECT
    fo.run_id, fo.panel, fo.build, fo.archetype_id, fo.question_key, fo.meta,
    c.cut, c.cut_value,
    s.is_sentinel, s.is_top_box, s.is_top2_box, s.is_bottom_box, s.is_bottom2_box,
    s.is_equated_top_box, s.latent_favourability,
    q.scale_max, q.rank_basis, q.construct_polarity, q.q_position
  FROM `PROJECT_ID.abr_20_curated.fct_response_option` fo
  JOIN `PROJECT_ID.abr_20_curated.dim_question_option_scaled` s
    USING (run_id, question_key, option_raw)
  JOIN `PROJECT_ID.abr_20_curated.dim_question_scale` q
    USING (run_id, question_key)
  JOIN `PROJECT_ID.abr_20_curated.dim_archetype_cut` c
    ON c.run_id = fo.run_id AND c.archetype_id = fo.archetype_id
  WHERE q.is_ordinal AND q.scale_role = 'favourability'
)
SELECT
  r.run_id, r.panel, r.build, r.meta, ANY_VALUE(r.q_position) AS q_position,
  SUBSTR(ANY_VALUE(dq.question_text), 1, 110) AS question_text,
  ANY_VALUE(r.construct_polarity) AS construct_polarity,
  ANY_VALUE(r.rank_basis) AS rank_basis,
  ANY_VALUE(r.scale_max) AS scale_points,
  r.cut, r.cut_value,
  COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)) AS base,
  COUNTIF(r.is_sentinel) AS sentinel_excluded,
  ROUND(100.0 * COUNTIF(r.is_top_box)
        / NULLIF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)), 0), 1)
    AS top_box_pct,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_low`(
    COUNTIF(r.is_top_box),
    COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL))), 1) AS tb_ci_low,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_high`(
    COUNTIF(r.is_top_box),
    COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL))), 1) AS tb_ci_high,
  -- a 2-point scale has no top-2 box. NULL, never 0.0 -- a fake zero reads as a
  -- measured zero and that is worse than reporting nothing.
  IF(ANY_VALUE(r.scale_max) >= 3,
     ROUND(100.0 * COUNTIF(r.is_top2_box)
           / NULLIF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)), 0), 1),
     NULL) AS top2_box_pct,
  ROUND(100.0 * COUNTIF(r.is_bottom_box)
        / NULLIF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)), 0), 1)
    AS bottom_box_pct,
  IF(ANY_VALUE(r.scale_max) >= 3,
     ROUND(100.0 * COUNTIF(r.is_bottom2_box)
           / NULLIF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)), 0), 1),
     NULL) AS bottom2_box_pct,
  ROUND(100.0 * COUNTIF(r.is_equated_top_box)
        / NULLIF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)), 0), 1)
    AS equated_top_box_pct,
  ROUND(AVG(r.latent_favourability), 1) AS latent_mean,
  IF(COUNT(DISTINCT IF(NOT r.is_sentinel, r.archetype_id, NULL)) >= 30, '',
     'BASE<30 -- counts only') AS base_flag
FROM resp r
JOIN `PROJECT_ID.abr_20_curated.dim_question` dq USING (run_id, question_key)
GROUP BY r.run_id, r.panel, r.build, r.meta, r.cut, r.cut_value;

CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.banner_nominal_share` AS
SELECT
  fo.run_id, fo.panel, fo.build, fo.meta, ANY_VALUE(q.q_position) AS q_position,
  SUBSTR(ANY_VALUE(dq.question_text), 1, 110) AS question_text,
  c.cut, c.cut_value, s.option_label,
  COUNT(*) AS n,
  COUNT(DISTINCT fo.archetype_id) AS personas,
  ROUND(100.0 * COUNT(DISTINCT fo.archetype_id) / MAX(t.base), 1) AS pct,
  MAX(t.base) AS base,
  IF(MAX(t.base) >= 30, '', 'BASE<30 -- counts only') AS base_flag
FROM `PROJECT_ID.abr_20_curated.fct_response_option` fo
JOIN `PROJECT_ID.abr_20_curated.dim_question_option_scaled` s
  USING (run_id, question_key, option_raw)
JOIN `PROJECT_ID.abr_20_curated.dim_question_scale` q USING (run_id, question_key)
JOIN `PROJECT_ID.abr_20_curated.dim_question` dq USING (run_id, question_key)
JOIN `PROJECT_ID.abr_20_curated.dim_archetype_cut` c
  ON c.run_id = fo.run_id AND c.archetype_id = fo.archetype_id
JOIN (
  SELECT fo.run_id, fo.question_key, c.cut, c.cut_value,
         COUNT(DISTINCT fo.archetype_id) AS base
  FROM `PROJECT_ID.abr_20_curated.fct_response_option` fo
  JOIN `PROJECT_ID.abr_20_curated.dim_archetype_cut` c
    ON c.run_id = fo.run_id AND c.archetype_id = fo.archetype_id
  GROUP BY 1, 2, 3, 4
) t ON t.run_id = fo.run_id AND t.question_key = fo.question_key
   AND t.cut = c.cut AND t.cut_value = c.cut_value
WHERE NOT q.is_ordinal OR q.scale_role = 'nominal'
GROUP BY fo.run_id, fo.panel, fo.build, fo.meta, c.cut, c.cut_value, s.option_label;

-- ---------------------------------------------------------------------------
-- Cross-run comparison. THIS IS THE VERSION TEST, and it is also the
-- cross-wave replication test -- they are the same query, because both ask
-- "the same question, asked twice, how much did the answer move?"
--
-- Matching is on (panel, normalised question text). A question whose WORDING
-- changed is a different question and is deliberately not matched.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.mart_run_comparison` AS
WITH totals AS (
  SELECT b.run_id, b.panel, b.build, b.meta, b.question_text, b.scale_points,
         b.base, b.top_box_pct, b.top2_box_pct, b.latent_mean,
         `PROJECT_ID.abr_00_config.fn_norm_text`(dq.question_text) AS question_text_norm,
         b.question_text AS qt
  FROM `PROJECT_ID.abr_30_marts.banner` b
  JOIN `PROJECT_ID.abr_20_curated.dim_question` dq
    ON dq.run_id = b.run_id AND dq.meta = b.meta AND dq.q_position = b.q_position
  WHERE b.cut = 'total'
),
labels AS (
  SELECT run_id, question_key, panel, meta,
         STRING_AGG(option_label_norm, ' | ' ORDER BY option_label_norm) AS label_set,
         ARRAY_AGG(DISTINCT option_label_norm) AS labels
  FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled`
  WHERE NOT is_sentinel
  GROUP BY run_id, question_key, panel, meta
),
label_by_run_meta AS (
  SELECT run_id, panel, meta, ANY_VALUE(labels) AS labels FROM labels
  GROUP BY run_id, panel, meta
),
pairs AS (
  SELECT
    a.panel,
    a.run_id AS run_a, b.run_id AS run_b,
    a.build AS build_a, b.build AS build_b,
    a.meta, a.qt AS question_text,
    a.scale_points AS points_a, b.scale_points AS points_b,
    a.base AS base_a, b.base AS base_b,
    a.top_box_pct AS tb_a, b.top_box_pct AS tb_b,
    a.top2_box_pct AS t2b_a, b.top2_box_pct AS t2b_b,
    a.latent_mean AS latent_a, b.latent_mean AS latent_b,
    ROUND(b.top_box_pct - a.top_box_pct, 1) AS raw_tb_delta,
    ROUND(b.latent_mean - a.latent_mean, 1) AS latent_delta,
    (SELECT COUNT(*) FROM UNNEST(la.labels) x
     WHERE x IN UNNEST(lb.labels)) AS shared_labels,
    ARRAY_LENGTH(la.labels) AS labels_a,
    ARRAY_LENGTH(lb.labels) AS labels_b
  FROM totals a
  JOIN totals b
    ON a.panel = b.panel AND a.question_text_norm = b.question_text_norm
   AND a.run_id < b.run_id
  LEFT JOIN label_by_run_meta la ON la.run_id = a.run_id AND la.panel = a.panel AND la.meta = a.meta
  LEFT JOIN label_by_run_meta lb ON lb.run_id = b.run_id AND lb.panel = b.panel AND lb.meta = b.meta
)
SELECT p.*,
  noise_floor AS noise_floor_used,
  CASE
    -- same construct, no shared option wording: two different questions.
    -- Comparing them is how a scale artefact gets published as a finding.
    WHEN IFNULL(p.shared_labels, 0) = 0 THEN 'not comparable -- option sets differ'
    WHEN p.points_a != p.points_b AND ABS(p.raw_tb_delta) - ABS(p.latent_delta) > 10
      THEN 'scale artefact -- do not report the raw gap'
    WHEN ABS(p.latent_delta) >= noise_floor THEN 'material'
    ELSE 'within run noise'
  END AS verdict
FROM pairs p;

-- Per-pair summary: the empirical noise floor and the rank-order agreement.
-- Rank order is the trustworthy part; levels need an anchor and rank order
-- does not.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.mart_run_agreement` AS
WITH cmp AS (
  SELECT * FROM `PROJECT_ID.abr_30_marts.mart_run_comparison`
  WHERE verdict != 'not comparable -- option sets differ'
    AND latent_a IS NOT NULL AND latent_b IS NOT NULL
),
ranked AS (
  SELECT panel, run_a, run_b, build_a, build_b, meta, latent_a, latent_b, latent_delta,
         RANK() OVER (PARTITION BY run_a, run_b ORDER BY latent_a) AS rank_a,
         RANK() OVER (PARTITION BY run_a, run_b ORDER BY latent_b) AS rank_b
  FROM cmp
)
SELECT
  panel, run_a, run_b, build_a, build_b,
  COUNT(*) AS matched_constructs,
  -- Spearman: Pearson correlation of the ranks
  ROUND(CORR(rank_a, rank_b), 3) AS rank_order_rho,
  ROUND(AVG(ABS(latent_delta)), 1) AS empirical_noise_floor,
  ROUND(MAX(ABS(latent_delta)), 1) AS largest_move,
  ROUND(AVG(latent_delta), 1) AS mean_signed_shift,
  COUNTIF(ABS(latent_delta) >= noise_floor) AS constructs_beyond_floor
FROM ranked
GROUP BY panel, run_a, run_b, build_a, build_b;

-- ---------------------------------------------------------------------------
-- Known-answer accuracy. The trailer said theatrical, and it said
-- January 22, 2027. These are checkable facts, not opinions, which makes them
-- the one form of validation available with no human benchmark at all.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.known_answer_accuracy` AS
WITH facts AS (
  SELECT * FROM UNNEST([
    STRUCT('DLOC' AS meta, r'movie theat(re|er)|in theat(re|er)s' AS pattern,
           'availability: in movie theatres' AS fact),
    ('KPRSE', r'movie theat(re|er)', 'availability: in movie theatres'),
    ('RETITLE', r'air bud returns', 'title: Air Bud Returns'),
    ('DRELEASE', r'january\s*22,?\s*2027|january\s*2027', 'release: January 22, 2027')
  ])
)
SELECT
  f.run_id, f.panel, f.build, f.meta, k.fact,
  COUNT(*) AS base,
  COUNTIF(REGEXP_CONTAINS(
    LOWER(CONCAT(IFNULL(f.selected_raw, ''), ' ', IFNULL(f.qual_clean, ''))),
    k.pattern)) AS correct,
  ROUND(100.0 * COUNTIF(REGEXP_CONTAINS(
    LOWER(CONCAT(IFNULL(f.selected_raw, ''), ' ', IFNULL(f.qual_clean, ''))),
    k.pattern)) / COUNT(*), 1) AS accuracy_pct,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_low`(
    COUNTIF(REGEXP_CONTAINS(
      LOWER(CONCAT(IFNULL(f.selected_raw, ''), ' ', IFNULL(f.qual_clean, ''))),
      k.pattern)), COUNT(*)), 1) AS ci_low,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_high`(
    COUNTIF(REGEXP_CONTAINS(
      LOWER(CONCAT(IFNULL(f.selected_raw, ''), ' ', IFNULL(f.qual_clean, ''))),
      k.pattern)), COUNT(*)), 1) AS ci_high
FROM `PROJECT_ID.abr_20_curated.fct_response` f
JOIN facts k ON k.meta = f.meta
WHERE f.answered
GROUP BY f.run_id, f.panel, f.build, f.meta, k.fact;

-- ---------------------------------------------------------------------------
-- What travels with theatrical intent. Rank correlation, so direction and
-- ordering only: n is in the hundreds and the panel's demographics are balanced
-- by design rather than drawn, so the usual sampling-error reading does not
-- apply and neither does a causal one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.intent_driver` AS
WITH intent AS (
  SELECT run_id, archetype_id, score AS intent_score
  FROM `PROJECT_ID.abr_30_marts.prose_score`
  WHERE meta = 'DTHEAT' AND score IS NOT NULL
),
metric AS (
  SELECT i.run_id, i.archetype_id, i.intent_score,
         q.meta, q.q_position, SUBSTR(dq.question_text, 1, 70) AS detail,
         AVG(s.latent_favourability) AS feature_value
  FROM intent i
  JOIN `PROJECT_ID.abr_20_curated.fct_response_option` fo
    ON fo.run_id = i.run_id AND fo.archetype_id = i.archetype_id
  JOIN `PROJECT_ID.abr_20_curated.dim_question_option_scaled` s
    USING (run_id, question_key, option_raw)
  JOIN `PROJECT_ID.abr_20_curated.dim_question_scale` q USING (run_id, question_key)
  JOIN `PROJECT_ID.abr_20_curated.dim_question` dq USING (run_id, question_key)
  WHERE q.is_ordinal AND q.scale_role = 'favourability'
    AND s.latent_favourability IS NOT NULL
  GROUP BY i.run_id, i.archetype_id, i.intent_score, q.meta, q.q_position, dq.question_text
),
theme AS (
  SELECT i.run_id, i.archetype_id, i.intent_score,
         t.theme_id AS meta, CAST(NULL AS INT64) AS q_position,
         'theme mention' AS detail,
         CAST(EXISTS (
           SELECT 1 FROM `PROJECT_ID.abr_30_marts.verbatim_code` v
           WHERE v.run_id = i.run_id AND v.archetype_id = i.archetype_id
             AND v.theme_id = t.theme_id AND v.source = 'verbatim') AS INT64)
           AS feature_value
  FROM intent i
  CROSS JOIN (SELECT DISTINCT theme_id FROM `PROJECT_ID.abr_00_config.codeframe`) t
),
combined AS (
  SELECT 'closed_end_metric' AS kind, * FROM metric
  UNION ALL SELECT 'theme_mention' AS kind, * FROM theme
),
ranked AS (
  SELECT kind, run_id, meta, q_position, detail,
         RANK() OVER (PARTITION BY kind, run_id, meta ORDER BY feature_value) AS rank_feature,
         RANK() OVER (PARTITION BY kind, run_id, meta ORDER BY intent_score) AS rank_intent,
         feature_value
  FROM combined
)
SELECT kind, run_id, meta AS feature, q_position, ANY_VALUE(detail) AS detail,
       COUNT(*) AS n,
       ROUND(CORR(rank_feature, rank_intent), 3) AS rho,
       -- a feature almost everybody or almost nobody has cannot be correlated
       -- honestly, so the lopsidedness is reported next to the number
       LEAST(COUNTIF(feature_value > 0), COUNT(*) - COUNTIF(feature_value > 0)) AS smaller_side
FROM ranked
GROUP BY kind, run_id, meta, q_position
HAVING n >= 60 AND smaller_side >= 15
ORDER BY ABS(rho) DESC;
