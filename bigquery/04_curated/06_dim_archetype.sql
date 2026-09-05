-- ============================================================================
-- STAGE 4a — dim_archetype  (one row per persona, 152 rows)
--
-- WHAT: the persona dimension, with every normalisation the Stage 3 checks
-- said was needed. Raw values are PRESERVED alongside normalised ones; nothing
-- is overwritten.
--
-- WHY keep both: when a banner number looks wrong, the first question is
-- always "what did the source actually say". If you overwrite archetype_race
-- with a cleaned value you can never answer it. The *_raw columns cost nothing
-- and settle arguments.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_archetype`
CLUSTER BY instrument, age_band AS
WITH unioned AS (
  SELECT instrument, age_band, source_file,
         archetype_id, group_name, archetype_name, archetype_title,
         archetype_age_range, archetype_gender, archetype_race,
         archetype_occupation, archetype_income_range, archetype_education_level,
         archetype_location, archetype_location_type,
         archetype_nps_score, archetype_adoption_category_name,
         archetype_behavioral_spark_name, archetype_persona_summary,
         archetype_political_affiliation
  FROM `PROJECT_ID.abr_10_raw.raw_t1`
  UNION ALL
  SELECT instrument, age_band, source_file,
         archetype_id, group_name, archetype_name, archetype_title,
         archetype_age_range, archetype_gender, archetype_race,
         archetype_occupation, archetype_income_range, archetype_education_level,
         archetype_location, archetype_location_type,
         archetype_nps_score, archetype_adoption_category_name,
         archetype_behavioral_spark_name, archetype_persona_summary,
         archetype_political_affiliation
  FROM `PROJECT_ID.abr_10_raw.raw_t23`
)
SELECT
  archetype_id,
  instrument,
  age_band,
  source_file,
  group_name,
  archetype_name,
  archetype_title,

  -- Age: clean single integers in this study (4-12), unlike the Fatal Fury
  -- data which needed bucket parsing. SAFE_CAST anyway — a NULL here is a
  -- loud failure, a silent 0 would not be.
  SAFE_CAST(TRIM(archetype_age_range) AS INT64)                AS age,
  archetype_age_range                                          AS age_raw,

  INITCAP(TRIM(archetype_gender))                              AS gender,

  -- CHECK 08 handling: collapse the "/" vs "or" separator fork. Four real
  -- categories, not seven. Raw kept for audit.
  CASE
    WHEN REGEXP_CONTAINS(archetype_race, r'(?i)asian')    THEN 'Asian / Pacific Islander'
    WHEN REGEXP_CONTAINS(archetype_race, r'(?i)black|african') THEN 'Black / African American'
    WHEN REGEXP_CONTAINS(archetype_race, r'(?i)latino|hispanic') THEN 'Latino / Hispanic'
    WHEN REGEXP_CONTAINS(archetype_race, r'(?i)white|caucasian') THEN 'White / Caucasian'
    ELSE 'Other / Unclassified'
  END                                                          AS ethnicity,
  archetype_race                                               AS ethnicity_raw,

  -- CHECK 09 handling: singularise "Early Adopters" -> "Early Adopter" etc.
  REGEXP_REPLACE(TRIM(archetype_adoption_category_name), r's$', '') AS adoption_category,
  archetype_adoption_category_name                             AS adoption_category_raw,

  TRIM(archetype_behavioral_spark_name)                        AS behavioral_spark,

  -- CHECK 14 handling: grade extracted as an integer so "5th Grade Student"
  -- and "Student (5th Grade)" stop being two different values.
  SAFE_CAST(REGEXP_EXTRACT(archetype_occupation, r'(\d+)') AS INT64) AS grade,
  archetype_occupation                                         AS occupation_raw,

  -- NPS: pre-assigned PERSONA METADATA, not a response to this trailer.
  -- Named defensively so nobody quotes it as a trailer metric by accident.
  SAFE_CAST(TRIM(archetype_nps_score) AS INT64)                AS persona_nps_input,

  TRIM(archetype_location)                                     AS location_raw,
  TRIM(archetype_location_type)                                AS location_type,
  TRIM(archetype_education_level)                              AS education_level,
  archetype_persona_summary                                    AS persona_summary,

  -- CHECK 11: income is free text (117 distinct / 152). Carried for reference,
  -- explicitly NOT parsed into bands, and flagged so it cannot become a cut.
  archetype_income_range                                       AS income_raw,
  FALSE                                                        AS income_is_usable_as_cut,

  -- CHECK 10: constants. Deliberately NOT selected into this dim
  -- (marital_status, children_status, children, field_of_study). Recorded here
  -- as a comment so a future reader knows the omission was a decision.

  CURRENT_TIMESTAMP()                                          AS built_at
FROM unioned;

-- GATE: 152 rows, 4 ethnicities, 9 ages, 2 instruments.
SELECT COUNT(*) AS personas,
       COUNT(DISTINCT ethnicity)  AS ethnicities,
       COUNT(DISTINCT age)        AS ages,
       COUNT(DISTINCT instrument) AS instruments,
       COUNTIF(age IS NULL)       AS null_ages
FROM `PROJECT_ID.abr_20_curated.dim_archetype`;
