-- v_response_metrics: the reusable box-metric layer. Every banner and model
-- binds here rather than recomputing top-box arithmetic.
--
-- Scale convention (banner plans, row 6): "qre PDF convention: 1 = best/top".
-- Option codes ascend worst, so:
--
--   Top Box      primary_code = 1
--   Top-2 Box    primary_code IN (1, 2)
--   Bottom Box   primary_code = scale_max
--   Bottom-2 Box primary_code IN (scale_max - 1, scale_max)
--
-- scale_max is per question and derived from the observed option universe with
-- sentinels excluded. It is never hardcoded: measured values across the 71
-- single-select ordinal questions are {1, 2, 3, 4, 6}. There is NO 5-point
-- scale anywhere in this study, so any formula assuming one is wrong on every
-- question.
--
-- KNOWN LIMITATION -- deferred by decision, revisit at Phase 1 close-out
-- ---------------------------------------------------------------------
-- These four flags treat option_code as an ordinal rank for every closed
-- question. That holds for 71 of 80. It does NOT hold for:
--
--   9 unordered multi-select pick-lists -- CHARDES, STORYDES, SOCIAL, ELEMENT2,
--     SEEWITH, PLATFORM, AUD2, GENREFIT, Screener 1 (all q_type 5). Here
--     option_code is a category id, not a rank: primary_code keeps only the
--     lowest-numbered pick and discards the rest, and "top box" on "which
--     social apps do you use" is not a quantity.
--
--   2 single-option formalities -- Screener 2 (country), INTRO2
--     (acknowledgement), scale_max = 1. is_bot is TRUE for everyone and
--     is_b2b compares against scale_max - 1 = 0.
--
-- Nothing in Phase 1 reads these flags, so no gate is affected. It matters once
-- banners are built on top. The fix, when taken, is a metric_kind column on
-- dim_question plus a fct_response_option table for per-option incidence --
-- which the plan doc names in its architecture but defines nowhere.
--
-- Until then: filter to ordinal questions before publishing any box metric.

CREATE OR REPLACE VIEW `${PROJECT_ID}.${DS_CUR}.v_response_metrics` AS
SELECT
  *,
  primary_code = 1                           AS is_tb,
  primary_code IN (1, 2)                     AS is_t2b,
  primary_code = scale_max                   AS is_bot,
  primary_code IN (scale_max - 1, scale_max)  AS is_b2b
FROM `${PROJECT_ID}.${DS_CUR}.fct_response`;
