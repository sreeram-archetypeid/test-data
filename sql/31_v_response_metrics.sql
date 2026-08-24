-- v_response_metrics: the box-metric layer. Every banner and model binds here
-- rather than recomputing top-box arithmetic.
--
-- Scale convention (banner plans, row 6): "qre PDF convention: 1 = best/top".
-- Option codes ascend worst, so:
--
--   Top Box      primary_code = 1
--   Top-2 Box    primary_code IN (1, 2)
--   Bottom Box   primary_code = scale_max
--   Bottom-2 Box primary_code IN (scale_max - 1, scale_max)
--
-- scale_max is per question, never hardcoded. Across the 69 genuine ordinal
-- questions the observed universe is {2, 3, 4, 6} -- there is NO 5-point scale
-- anywhere in this study, so any formula assuming one is wrong on every
-- question.
--
-- The gate on metric_kind
-- -----------------------
-- Each flag returns NULL unless the question is ordinal_scale. This is the
-- Phase 1 close-out fix: previously the flags were computed for all 80 closed
-- questions, but 11 of them are not ordinal --
--
--   9 unordered multi-select pick-lists (CHARDES, STORYDES, SOCIAL, ELEMENT2,
--     SEEWITH, PLATFORM, AUD2, GENREFIT, Screener 1), where option_code is a
--     category id and primary_code silently keeps only the lowest-numbered pick
--   2 single-option formalities (INTRO2, Screener 2) where scale_max = 1, so
--     is_bot was TRUE for everyone and is_b2b compared against 0
--
-- Effect of the gate, measured: is_tb TRUE drops from 13,451 to 11,414. Those
-- 2,037 rows were being counted as "top box" on questions where the phrase has
-- no meaning. A wrong number is now an ABSENT number -- an analyst who reads
-- is_tb on CHARDES gets NULL, not a plausible 34%.
--
-- For the 9 multi_select questions, use fct_response_option and report incidence
-- (share of respondents selecting each option) instead.

CREATE OR REPLACE VIEW `${PROJECT_ID}.${DS_CUR}.v_response_metrics` AS
SELECT
  f.*,
  q.metric_kind,
  IF(q.metric_kind = 'ordinal_scale', f.primary_code = 1,        NULL) AS is_tb,
  IF(q.metric_kind = 'ordinal_scale', f.primary_code IN (1, 2),  NULL) AS is_t2b,
  IF(q.metric_kind = 'ordinal_scale', f.primary_code = f.scale_max, NULL) AS is_bot,
  IF(q.metric_kind = 'ordinal_scale',
     f.primary_code IN (f.scale_max - 1, f.scale_max), NULL) AS is_b2b
FROM `${PROJECT_ID}.${DS_CUR}.fct_response` AS f
JOIN `${PROJECT_ID}.${DS_CUR}.dim_question` AS q
  USING (question_key);
