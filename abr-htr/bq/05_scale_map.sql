-- ============================================================================
-- Stage 5: what does "top box" mean? Resolved per question, and provable.
-- ============================================================================
-- This is the highest-risk artefact in the build, so it is deterministic,
-- inspectable as rows, and it refuses to guess quietly.
--
-- Three facts about this data force the design:
--
--  1. Option codes exist but their direction is NOT fixed. KPLIKE2 runs 1=best;
--     KPWANT, four columns later in the same file, runs 5=best. A global
--     "top box = code 1" rule reports the bottom box as the top box on half the
--     battery.
--  2. 22 questions print a second scale number inside the label
--     ("2. 4 - To a great extent") and on 20 of them it runs OPPOSITE to the
--     code. The printed point is the questionnaire's scale; the code is an
--     artefact of option ordering.
--  3. One kids panel asks 3-point scales where the other asks 5-point ones for
--     the same construct. Counting boxes cannot cross them -- that is exactly how
--     the earlier wave's spurious "37-54 point appeal collapse" was manufactured.
--     So every option also gets a 0-100 latent score, which can.
--
-- Resolution order: printed scale point -> lexicon ladder -> option code
-- (flagged). Favourability then flips for negative constructs ("Not at all" is
-- the BEST answer to "did any part feel boring?") and becomes
-- distance-from-optimum for the too-little/right-amount/too-much items.
--
-- Anything unresolved or self-contradictory lands in dim_question_review and is
-- the ONLY thing the AI pass in 11_ai_scale_rank.sql is asked about.
-- ============================================================================

DECLARE theta FLOAT64 DEFAULT 75.0;   -- latent threshold for equated top box

CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question_option_scaled`
CLUSTER BY run_id, meta AS
WITH opt AS (
  SELECT
    o.run_id, o.panel, o.build, o.question_key, o.meta, o.q_position,
    o.option_raw, o.option_code, o.printed_scale_point,
    o.option_label, o.option_label_norm, o.n_selected,
    q.question_text, q.channel,
    `PROJECT_ID.abr_00_config.fn_norm_text`(q.question_text) AS question_text_norm
  FROM `PROJECT_ID.abr_20_curated.dim_question_option` o
  JOIN `PROJECT_ID.abr_20_curated.dim_question` q USING (run_id, question_key)
  WHERE q.channel != 'open_end'
),
-- outside the ordered scale: excluded from every box, the mean and the scale
-- length. Identified by LABEL, never by code -- these sit at code 6 in one
-- question and code 3 in another, sometimes mid-scale.
sentinel AS (
  SELECT o.*, EXISTS (
    SELECT 1 FROM `PROJECT_ID.abr_00_config.scale_sentinel` s
    WHERE o.option_label_norm = s.phrase
       OR STARTS_WITH(o.option_label_norm, s.phrase || ' ')
       OR STRPOS(' ' || o.option_label_norm, ' ' || s.phrase) > 0
  ) AS is_sentinel
  FROM opt o
),
-- longest matching phrase wins, so 'not at all' beats 'at all' and
-- 'very uncomfortable' beats 'very'
lex AS (
  SELECT s.*, i.intensity AS lex_intensity, i.phrase AS lex_phrase
  FROM sentinel s
  LEFT JOIN `PROJECT_ID.abr_00_config.scale_intensity` i
    ON STRPOS(s.option_label_norm, i.phrase) > 0
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY s.run_id, s.question_key, s.option_raw
    ORDER BY LENGTH(IFNULL(i.phrase, '')) DESC) = 1
),
polarity AS (
  SELECT question_text_norm,
    COALESCE(
      MAX(IF(p.polarity = 'mid_optimal', 'mid_optimal', NULL)),
      MAX(IF(p.polarity = 'negative', 'negative', NULL)),
      'positive') AS construct_polarity
  FROM (SELECT DISTINCT question_text_norm FROM lex) t
  LEFT JOIN `PROJECT_ID.abr_00_config.construct_polarity` p
    ON STRPOS(t.question_text_norm, p.pattern) > 0
  GROUP BY question_text_norm
),
q_agg AS (
  SELECT
    l.run_id, l.question_key,
    COUNTIF(NOT l.is_sentinel) AS n_live,
    COUNTIF(NOT l.is_sentinel AND l.printed_scale_point IS NOT NULL) AS n_printed,
    COUNTIF(NOT l.is_sentinel AND l.lex_intensity IS NOT NULL) AS n_lex,
    COUNT(*) AS n_options,
    LOGICAL_OR(l.meta IN (SELECT meta FROM `PROJECT_ID.abr_00_config.nominal_meta`))
      AS meta_is_nominal,
    ANY_VALUE(l.channel) AS channel,
    -- a wh-question whose options the ladder cannot place is a pick list, not a
    -- scale: "who would you watch with", "what kind of movie is this"
    LOGICAL_OR(REGEXP_CONTAINS(l.question_text,
      r'(?i)^\s*(\[[^\]]*\]\s*)?(which|who|what kind|what type|where|whom)\b')) AS is_wh,
    -- an option code carrying two different labels is a data defect worth naming
    COUNT(DISTINCT l.option_code) AS n_distinct_codes,
    COUNT(DISTINCT IF(NOT l.is_sentinel, l.option_label_norm, NULL)) AS n_distinct_labels,
    -- the questionnaire and the export can disagree about which option list
    -- belongs to a question: an agree/disagree battery attached to a
    -- too-little/right-amount/too-much item has no honest ranking
    LOGICAL_OR(STRPOS(l.option_label_norm, 'agree') > 0) AS has_agree_labels,
    LOGICAL_OR(REGEXP_CONTAINS(l.option_label_norm,
      r'right amount|too much|too little')) AS has_amount_labels
  FROM lex l
  GROUP BY l.run_id, l.question_key
),
basis AS (
  SELECT a.*, p.construct_polarity,
    CASE
      WHEN a.n_live < 2 THEN 'single_option_observed'
      WHEN p.construct_polarity = 'mid_optimal'
           AND a.has_agree_labels AND NOT a.has_amount_labels
        THEN 'label_question_mismatch'
      WHEN a.n_printed >= 2 AND a.n_printed = a.n_live THEN 'printed_scale_point'
      WHEN a.n_lex = a.n_live AND a.n_live >= 2 THEN 'lexicon'
      WHEN a.meta_is_nominal OR a.channel = 'multi_select'
           OR (a.is_wh AND a.n_lex < GREATEST(2, CAST(0.6 * a.n_live AS INT64)))
        THEN 'nominal'
      WHEN a.n_lex >= GREATEST(2, CAST(0.6 * a.n_live AS INT64)) THEN 'lexicon_partial'
      ELSE 'option_code'
    END AS rank_basis
  FROM q_agg a
  JOIN (SELECT DISTINCT l.run_id, l.question_key, l.question_text_norm FROM lex l) k
    USING (run_id, question_key)
  JOIN polarity p USING (question_text_norm)
),
scored AS (
  SELECT l.*, b.rank_basis, b.construct_polarity, b.n_live, b.n_printed, b.n_lex,
    b.n_distinct_codes, b.n_distinct_labels,
    CASE
      WHEN l.is_sentinel THEN NULL
      WHEN b.rank_basis = 'printed_scale_point' THEN CAST(l.printed_scale_point AS FLOAT64)
      WHEN b.rank_basis IN ('lexicon', 'lexicon_partial') THEN l.lex_intensity
      WHEN b.rank_basis = 'option_code' THEN -CAST(l.option_code AS FLOAT64)
    END AS intensity
  FROM lex l JOIN basis b USING (run_id, question_key)
),
-- the mid-optimal items rank by distance from the middle of the scale, so the
-- median has to be computed before the ranking rather than inside it
q_median AS (
  SELECT run_id, question_key,
         APPROX_QUANTILES(intensity, 2)[OFFSET(1)] AS median_intensity,
         MAX(intensity) AS max_intensity
  FROM scored
  WHERE intensity IS NOT NULL
  GROUP BY run_id, question_key
),
-- dense rank over DISTINCT scale positions, not over options. Two options that
-- share a printed point are ONE position: the current wave has a stray
-- "Neither agree nor disagree" sitting on printed 3, and ranking per option
-- would silently turn a 5-point scale into a 6-point one and move its top box.
ranked AS (
  SELECT s.*, m.max_intensity,
    DENSE_RANK() OVER (
      PARTITION BY s.run_id, s.question_key
      ORDER BY CASE s.construct_polarity
                 WHEN 'negative' THEN s.intensity                        -- least intense = best
                 WHEN 'mid_optimal' THEN ABS(s.intensity - m.median_intensity)
                 ELSE -s.intensity                                       -- most intense = best
               END) AS favourability_rank
  FROM scored s
  JOIN q_median m USING (run_id, question_key)
  WHERE s.intensity IS NOT NULL
),
positions AS (
  SELECT run_id, question_key, MAX(favourability_rank) AS scale_max
  FROM ranked GROUP BY run_id, question_key
),
latent AS (
  SELECT r.*, p.scale_max,
    CASE
      -- where the label prints its own point the instrument's full scale is
      -- known (a printed 5 means a 5-point scale), so anchor the axis to
      -- 1..max_printed rather than to the options that happened to be chosen
      WHEN r.rank_basis = 'printed_scale_point' AND r.construct_polarity = 'positive'
           AND r.max_intensity > 1
        THEN ROUND(100.0 * (r.intensity - 1) / (r.max_intensity - 1), 1)
      WHEN p.scale_max > 1
        THEN ROUND(100.0 * (p.scale_max - r.favourability_rank) / (p.scale_max - 1), 1)
      ELSE 100.0
    END AS latent_favourability
  FROM ranked r JOIN positions p USING (run_id, question_key)
)
SELECT
  s.run_id, s.panel, s.build, s.question_key, s.meta, s.q_position,
  s.option_raw, s.option_code, s.printed_scale_point, s.option_label,
  s.option_label_norm, s.n_selected,
  s.rank_basis, s.construct_polarity, s.is_sentinel,
  s.lex_phrase AS matched_phrase, s.intensity,
  l.favourability_rank, l.scale_max, l.latent_favourability,
  CAST(l.favourability_rank = 1 AS BOOL) AS is_top_box,
  CAST(l.favourability_rank <= 2 AND l.scale_max >= 3 AS BOOL) AS is_top2_box,
  CAST(l.favourability_rank = l.scale_max AS BOOL) AS is_bottom_box,
  CAST(l.favourability_rank >= l.scale_max - 1 AND l.scale_max >= 3 AS BOOL) AS is_bottom2_box,
  CAST(l.latent_favourability >= theta AS BOOL) AS is_equated_top_box,
  CAST(l.latent_favourability >= 50.0 AS BOOL) AS is_equated_top2_box
FROM scored s
LEFT JOIN latent l USING (run_id, question_key, option_raw);

-- ---------------------------------------------------------------------------
-- One row per question: the decision, and why. Read this before quoting a
-- number, and read dim_question_review before publishing one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question_scale` AS
WITH per_q AS (
  SELECT
    s.run_id, s.panel, s.build, s.question_key, s.meta, ANY_VALUE(s.q_position) AS q_position,
    ANY_VALUE(s.rank_basis) AS rank_basis,
    ANY_VALUE(s.construct_polarity) AS construct_polarity,
    MAX(s.scale_max) AS scale_max,
    COUNT(*) AS n_options,
    COUNTIF(s.is_sentinel) AS n_sentinel,
    COUNTIF(s.favourability_rank IS NOT NULL) AS n_ranked,
    -- does the export's code order track the scale at all?
    CORR(CAST(s.option_code AS FLOAT64), s.intensity) AS code_intensity_corr,
    COUNT(DISTINCT s.option_code) AS n_distinct_codes,
    COUNT(DISTINCT IF(NOT s.is_sentinel, s.option_label_norm, NULL)) AS n_distinct_labels
  FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled` s
  GROUP BY s.run_id, s.panel, s.build, s.question_key, s.meta
)
SELECT p.*, q.question_text, q.channel, q.q_type,
  -- ordinal but a CUT, not a verdict on the film: frequency, ownership and
  -- familiarity items. Ranking them is fine; publishing a top box on religious
  -- attendance is not.
  CASE WHEN p.rank_basis = 'nominal' THEN 'nominal'
       WHEN EXISTS (SELECT 1 FROM `PROJECT_ID.abr_00_config.behavioural_stem` b
                    WHERE STARTS_WITH(`PROJECT_ID.abr_00_config.fn_norm_text`(q.question_text),
                                      b.stem))
         THEN 'behavioural'
       ELSE 'favourability' END AS scale_role,
  CAST(p.rank_basis NOT IN ('nominal', 'single_option_observed', 'label_question_mismatch')
       AND p.n_ranked > 0 AS BOOL) AS is_ordinal,
  ARRAY_TO_STRING([
    IF(p.rank_basis = 'option_code', 'ranked by option code only -- direction unverified', ''),
    IF(p.rank_basis = 'lexicon_partial',
       FORMAT('lexicon covers %d of %d options', p.n_ranked, p.n_options - p.n_sentinel), ''),
    IF(p.rank_basis = 'label_question_mismatch',
       'option labels are an agree/disagree battery but the question asks '
       || 'too little / right amount / too much -- wrong option list attached', ''),
    IF(p.n_distinct_labels > p.n_distinct_codes,
       'an option code carries more than one label', ''),
    IF(p.rank_basis IN ('printed_scale_point', 'lexicon') AND p.n_ranked >= 3
       AND ABS(IFNULL(p.code_intensity_corr, 0)) < 0.5,
       FORMAT('option code does not track intensity (corr=%.2f)',
              IFNULL(p.code_intensity_corr, 0)), '')
  ], '; ') AS flags
FROM per_q p
JOIN `PROJECT_ID.abr_20_curated.dim_question` q USING (run_id, question_key);

CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question_review` AS
SELECT s.*, (
    SELECT STRING_AGG(o.option_raw, ' | ' ORDER BY o.option_raw)
    FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled` o
    WHERE o.run_id = s.run_id AND o.question_key = s.question_key
  ) AS option_block
FROM `PROJECT_ID.abr_20_curated.dim_question_scale` s
WHERE TRIM(s.flags) != ''
  AND s.rank_basis NOT IN ('nominal', 'single_option_observed');
