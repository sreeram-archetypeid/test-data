-- ============================================================================
-- Stage 4: the curated model. This is what analysis binds to.
-- ============================================================================
-- GRAIN, stated once because everything downstream depends on it:
--   dim_run              (run_id)
--   dim_archetype        (run_id, archetype_id)
--   dim_aat              (run_id, archetype_id)
--   dim_question         (run_id, question_key)     question_key is version-stable
--   dim_question_option  (run_id, question_key, option_raw)
--   fct_response         (run_id, archetype_id, question_key)
--   fct_response_option  (run_id, archetype_id, question_key, option_raw)
--
-- Nothing is ever deduplicated across runs. Two builds of the same panel
-- coexist; the difference between them is the measurement, not noise.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- dim_question. Identity is (panel, meta, question_text) -- see fn_question_key.
-- A question asked TWICE in one instrument collides on that identity. Do not
-- merge and do not drop: suffix the second key, record the parent, and measure
-- how often the two answers agree. In the current wave adult Q32/Q33 are
-- byte-identical statements answered identically by 272 of 273 personas;
-- reporting both double-counts the battery, and the disagreement rate is a free
-- intra-interview stability read.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question`
CLUSTER BY run_id, meta AS
WITH per_slot AS (
  SELECT
    run_id, panel, build, q_position,
    ANY_VALUE(meta) AS meta,
    ANY_VALUE(question_text) AS question_text,
    ANY_VALUE(q_type) AS q_type,
    COUNT(DISTINCT meta) AS meta_variants,
    COUNT(DISTINCT question_text) AS text_variants,
    COUNT(DISTINCT q_type) AS type_variants,
    COUNTIF(selected_raw IS NOT NULL AND selected_raw != '') AS n_selected,
    COUNTIF(qual_raw IS NOT NULL AND qual_raw != '') AS n_qual
  FROM `PROJECT_ID.abr_10_staging.stg_response`
  GROUP BY run_id, panel, build, q_position
),
keyed AS (
  SELECT *,
    `PROJECT_ID.abr_00_config.fn_question_key`(panel, meta, question_text) AS base_key,
    `PROJECT_ID.abr_00_config.fn_norm_text`(question_text) AS question_text_norm,
    ROW_NUMBER() OVER (
      PARTITION BY run_id,
        `PROJECT_ID.abr_00_config.fn_question_key`(panel, meta, question_text)
      ORDER BY q_position) AS dup_ordinal
  FROM per_slot
)
SELECT
  IF(dup_ordinal = 1, base_key, FORMAT('%s_d%d', base_key, dup_ordinal)) AS question_key,
  IF(dup_ordinal = 1, CAST(NULL AS STRING), base_key) AS duplicate_of_key,
  dup_ordinal AS duplicate_ordinal,
  run_id, panel, build, q_position, meta, question_text, question_text_norm, q_type,
  CASE q_type WHEN '1' THEN 'open_end' WHEN '5' THEN 'multi_select'
              WHEN '4' THEN 'single_select' ELSE 'unknown' END AS channel,
  meta_variants, text_variants, type_variants, n_selected, n_qual
FROM keyed;

-- ---------------------------------------------------------------------------
-- fct_response: one row per persona x question. The analysis grain.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.fct_response`
CLUSTER BY run_id, meta AS
SELECT
  s.run_id, s.panel, s.build, s.archetype_id,
  q.question_key, s.q_position, s.meta, s.q_type, q.channel,
  s.selected_raw,
  ARRAY_LENGTH(SPLIT(IFNULL(s.selected_raw, ''), '|')) -
    IF(IFNULL(s.selected_raw, '') = '', 1, 0) AS n_selected,
  s.rating_raw,
  s.qual_raw,
  `PROJECT_ID.abr_00_config.fn_strip_stage`(s.qual_raw) AS qual_clean,
  `PROJECT_ID.abr_00_config.fn_n_stage`(s.qual_raw) AS n_stage_directions,
  -- Generation-harness JSON that leaked into a data cell. Quarantined here so no
  -- semantic stage has to remember to exclude it.
  CAST(REGEXP_CONTAINS(LOWER(IFNULL(s.qual_raw, '')),
       r'mixtureofexperts|residualrisks|selfcritique')
       OR (STARTS_WITH(TRIM(IFNULL(s.qual_raw, '')), '{') AND LENGTH(s.qual_raw) > 400)
       AS BOOL) AS is_harness_leak,
  CAST(COALESCE(s.selected_raw, '') != '' OR COALESCE(s.qual_raw, '') != ''
       OR COALESCE(s.rating_raw, '') != '' AS BOOL) AS answered,
  s.source_file
FROM `PROJECT_ID.abr_10_staging.stg_response` s
JOIN `PROJECT_ID.abr_20_curated.dim_question` q
  USING (run_id, q_position);

-- ---------------------------------------------------------------------------
-- fct_response_option: multi-selects exploded. Pipe-delimited in every export.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.fct_response_option`
CLUSTER BY run_id, meta AS
SELECT
  f.run_id, f.panel, f.build, f.archetype_id, f.question_key, f.q_position, f.meta,
  TRIM(opt) AS option_raw,
  `PROJECT_ID.abr_00_config.fn_option_code`(TRIM(opt)) AS option_code,
  `PROJECT_ID.abr_00_config.fn_option_printed`(TRIM(opt)) AS printed_scale_point,
  `PROJECT_ID.abr_00_config.fn_option_label`(TRIM(opt)) AS option_label,
  `PROJECT_ID.abr_00_config.fn_norm_text`(
    `PROJECT_ID.abr_00_config.fn_option_label`(TRIM(opt))) AS option_label_norm
FROM `PROJECT_ID.abr_20_curated.fct_response` f,
     UNNEST(SPLIT(f.selected_raw, '|')) AS opt
WHERE TRIM(IFNULL(opt, '')) != '';

CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question_option`
CLUSTER BY run_id, meta AS
SELECT
  run_id, panel, build, question_key, meta, ANY_VALUE(q_position) AS q_position,
  option_raw, ANY_VALUE(option_code) AS option_code,
  ANY_VALUE(printed_scale_point) AS printed_scale_point,
  ANY_VALUE(option_label) AS option_label,
  ANY_VALUE(option_label_norm) AS option_label_norm,
  COUNT(*) AS n_selected
FROM `PROJECT_ID.abr_20_curated.fct_response_option`
GROUP BY run_id, panel, build, question_key, meta, option_raw;

-- ---------------------------------------------------------------------------
-- dim_archetype and dim_aat are built dynamically: the attribute columns differ
-- between instruments (the earlier wave has no aat_* block at all), so the
-- procedure takes the union of columns across every registered run and fills
-- what a given export does not have with NULL.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE `PROJECT_ID.abr_00_config.sp_build_persona_dims`()
BEGIN
  DECLARE attr_cols, aat_cols ARRAY<STRING>;
  DECLARE sql STRING;

  SET attr_cols = (
    SELECT ARRAY_AGG(DISTINCT column_name ORDER BY column_name)
    FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE STARTS_WITH(table_name, 'raw_')
      AND (STARTS_WITH(column_name, 'archetype_')
           OR column_name IN ('group_name', 'sample_name')));
  SET aat_cols = (
    SELECT ARRAY_AGG(DISTINCT column_name ORDER BY column_name)
    FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE STARTS_WITH(table_name, 'raw_') AND STARTS_WITH(column_name, 'aat_'));

  -- dim_archetype
  SET sql = (
    SELECT STRING_AGG(FORMAT("""
SELECT '%s' AS run_id, '%s' AS panel, '%s' AS instrument, '%s' AS build,
       '%s' AS export_date, %d AS run_seq, %s
FROM `PROJECT_ID.abr_01_raw.raw_%s`""",
      r.run_id, r.panel, r.instrument, r.build, IFNULL(r.export_date, ''), r.run_seq,
      (SELECT STRING_AGG(
         IF(c IN UNNEST((SELECT ARRAY_AGG(column_name)
                         FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
                         WHERE table_name = 'raw_' || r.run_id)),
            FORMAT('`%s`', c), FORMAT('CAST(NULL AS STRING) AS `%s`', c)), ', ')
       FROM UNNEST(attr_cols) AS c),
      r.run_id), '\nUNION ALL\n')
    FROM `PROJECT_ID.abr_20_curated.dim_run` r);

  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_archetype_raw`
    CLUSTER BY run_id AS %s""", sql);

  -- dim_aat
  IF ARRAY_LENGTH(aat_cols) > 0 THEN
    SET sql = (
      SELECT STRING_AGG(FORMAT("""
SELECT '%s' AS run_id, '%s' AS panel, '%s' AS build, archetype_id, %s
FROM `PROJECT_ID.abr_01_raw.raw_%s`""",
        r.run_id, r.panel, r.build,
        (SELECT STRING_AGG(
           IF(c IN UNNEST((SELECT ARRAY_AGG(column_name)
                           FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
                           WHERE table_name = 'raw_' || r.run_id)),
              FORMAT('`%s`', c), FORMAT('CAST(NULL AS STRING) AS `%s`', c)), ', ')
         FROM UNNEST(aat_cols) AS c),
        r.run_id), '\nUNION ALL\n')
      FROM `PROJECT_ID.abr_20_curated.dim_run` r);
    EXECUTE IMMEDIATE FORMAT("""
      CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_aat_raw`
      CLUSTER BY run_id AS %s""", sql);
  END IF;

  SELECT FORMAT('built dim_archetype_raw (%d attribute columns) and dim_aat_raw (%d columns)',
                ARRAY_LENGTH(attr_cols), ARRAY_LENGTH(aat_cols)) AS result;
END;

-- ---------------------------------------------------------------------------
-- Derived persona columns. Source values are never overwritten -- every
-- normalised value gets a new name, so a bad parse stays recoverable.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.dim_archetype` AS
SELECT
  a.*,
  `PROJECT_ID.abr_00_config.fn_gender_norm`(a.archetype_gender) AS gender_norm,
  `PROJECT_ID.abr_00_config.fn_age_exact`(a.archetype_age_range) AS age_exact,
  COALESCE(
    `PROJECT_ID.abr_00_config.fn_age_band`(
      `PROJECT_ID.abr_00_config.fn_age_exact`(a.archetype_age_range)),
    -- a clean bucket whose ends fall in one band
    IF(`PROJECT_ID.abr_00_config.fn_age_band`(
         SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'^\s*([0-9]{1,3})\s*-') AS INT64))
       = `PROJECT_ID.abr_00_config.fn_age_band`(
         SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'-\s*([0-9]{1,3})\s*$') AS INT64)),
       `PROJECT_ID.abr_00_config.fn_age_band`(
         SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'^\s*([0-9]{1,3})\s*-') AS INT64)),
       NULL),
    -- a bucket that straddles two bands: midpoint, and flagged below
    `PROJECT_ID.abr_00_config.fn_age_band`(
      DIV(SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'^\s*([0-9]{1,3})\s*-') AS INT64)
          + SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'-\s*([0-9]{1,3})\s*$') AS INT64), 2))
  ) AS age_band,
  CAST(`PROJECT_ID.abr_00_config.fn_age_exact`(a.archetype_age_range) IS NULL
       AND REGEXP_CONTAINS(IFNULL(a.archetype_age_range, ''), r'[0-9]+\s*-\s*[0-9]+')
       AND `PROJECT_ID.abr_00_config.fn_age_band`(
             SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'^\s*([0-9]{1,3})\s*-') AS INT64))
           != `PROJECT_ID.abr_00_config.fn_age_band`(
             SAFE_CAST(REGEXP_EXTRACT(a.archetype_age_range, r'-\s*([0-9]{1,3})\s*$') AS INT64))
       AS BOOL) AS age_band_is_imputed,
  -- income is free text: '$50,000 - $75,000 (Household)', 'Dependent (Household: $65,000)'
  SAFE_CAST(REGEXP_REPLACE(
    REGEXP_EXTRACT(a.archetype_income_range, r'\$\s*([0-9,]+)'), ',', '') AS INT64)
    AS income_low_usd,
  SAFE_CAST(REGEXP_REPLACE(
    ARRAY_REVERSE(REGEXP_EXTRACT_ALL(IFNULL(a.archetype_income_range, ''),
                                     r'\$\s*([0-9,]+)'))[SAFE_OFFSET(0)], ',', '') AS INT64)
    AS income_high_usd,
  REGEXP_CONTAINS(LOWER(IFNULL(a.archetype_income_range, '')), r'household') AS income_is_household,
  SAFE_CAST(a.archetype_nps_score AS INT64) AS nps_score_num,
  a.group_name AS group_code
FROM `PROJECT_ID.abr_20_curated.dim_archetype_raw` a;

-- Banner cuts, long. Deliberately short: the kids panels cannot carry a
-- demographic banner -- one of them is n=25 in total -- so the adult panel
-- carries the cuts and the kids panels are read as counts.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.dim_archetype_cut` AS
SELECT run_id, archetype_id, 'total' AS cut, 'total' AS cut_value
FROM `PROJECT_ID.abr_20_curated.dim_archetype`
UNION ALL SELECT run_id, archetype_id, 'panel', panel
FROM `PROJECT_ID.abr_20_curated.dim_archetype`
UNION ALL SELECT run_id, archetype_id, 'build', build
FROM `PROJECT_ID.abr_20_curated.dim_archetype`
UNION ALL SELECT run_id, archetype_id, 'gender', gender_norm
FROM `PROJECT_ID.abr_20_curated.dim_archetype` WHERE gender_norm IS NOT NULL
UNION ALL SELECT run_id, archetype_id, 'age_band', age_band
FROM `PROJECT_ID.abr_20_curated.dim_archetype` WHERE age_band IS NOT NULL
UNION ALL SELECT run_id, archetype_id, 'group', group_code
FROM `PROJECT_ID.abr_20_curated.dim_archetype` WHERE COALESCE(group_code, '') != ''
UNION ALL SELECT run_id, archetype_id, 'adoption',
       REGEXP_REPLACE(TRIM(archetype_adoption_category_name), r's$', '')
FROM `PROJECT_ID.abr_20_curated.dim_archetype`
WHERE COALESCE(archetype_adoption_category_name, '') != '';

-- The aat_* block: typed, split, and with the nested JSON exposed. The flat
-- columns are a projection of aat_diagnostics_json, which is the source of truth.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.dim_aat` AS
SELECT
  a.*,
  SAFE_CAST(a.aat_pre_concept_interest_pct AS INT64) AS pre_concept_interest_num,
  SAFE_CAST(a.aat_post_concept_interest_pct AS INT64) AS post_concept_interest_num,
  SAFE_CAST(a.aat_interest_delta AS INT64) AS interest_delta_num,
  SAFE_CAST(a.aat_playability_score AS INT64) AS playability_score_num,
  SAFE_CAST(a.aat_polarization_risk AS INT64) AS polarization_risk_num,
  SAFE_CAST(a.aat_organic_evangelism AS INT64) AS organic_evangelism_num,
  SAFE_CAST(a.aat_pact_fulfillment_score AS INT64) AS pact_fulfillment_score_num,
  CASE `PROJECT_ID.abr_00_config.fn_norm_text`(a.aat_top_box_category)
    WHEN 'definitely interested' THEN 4 WHEN 'probably interested' THEN 3
    WHEN 'probably not interested' THEN 2 WHEN 'definitely not interested' THEN 1 END
    AS top_box_category_rank,
  CASE `PROJECT_ID.abr_00_config.fn_norm_text`(a.aat_opening_weekend_intent)
    WHEN 'opening weekend theater' THEN 3 WHEN 'wait for streaming' THEN 2
    WHEN 'never watch' THEN 1 END AS opening_weekend_intent_rank,
  -- 'High|Will use pester power to demand tickets' -> band + rationale
  IF(SPLIT(a.aat_playability_recommend, '|')[SAFE_OFFSET(0)] IN ('Low', 'Med', 'High'),
     SPLIT(a.aat_playability_recommend, '|')[SAFE_OFFSET(0)], NULL)
    AS playability_recommend_band,
  SPLIT(a.aat_playability_recommend, '|')[SAFE_OFFSET(1)] AS playability_recommend_note,
  JSON_VALUE(a.aat_diagnostics_json, '$.quantitativeMetrics.rawInterestDelta')
    AS json_interest_delta,
  JSON_VALUE(a.aat_diagnostics_json,
             '$.postViewingState.archetypeIDPlayabilityScore.definiteRecommendProbability')
    AS json_definite_recommend_probability
FROM `PROJECT_ID.abr_20_curated.dim_aat_raw` a;
