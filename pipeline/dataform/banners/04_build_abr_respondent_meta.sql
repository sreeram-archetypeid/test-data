-- ABR respondent meta cuts (W-Tabs style).
-- Source: staging raw tables already loaded for drop-002.
-- Only categorical, banner-safe fields (not free-text aat_* / persona prose).

CREATE OR REPLACE TABLE `archetypeid-staging.svy.abr_respondent_meta` AS

WITH raw AS (
  SELECT
    'drop-002' AS study_id,
    CAST(archetype_id AS STRING) AS respondent_id,
    'HTR' AS sample_arm,
    CAST(archetype_gender AS STRING) AS gender_raw,
    CAST(archetype_age_range AS STRING) AS age_raw,
    CAST(archetype_race AS STRING) AS race_raw,
    CAST(archetype_location_type AS STRING) AS location_type_raw,
    CAST(archetype_adoption_category_name AS STRING) AS adoption_raw,
    CAST(archetype_children_status AS STRING) AS children_status_raw
  FROM `archetypeid-staging.svy_stg.abr_raw_htr`

  UNION ALL

  SELECT
    'drop-002',
    CAST(archetype_id AS STRING),
    'K3',
    CAST(archetype_gender AS STRING),
    CAST(archetype_age_range AS STRING),
    CAST(archetype_race AS STRING),
    CAST(archetype_location_type AS STRING),
    CAST(archetype_adoption_category_name AS STRING),
    CAST(archetype_children_status AS STRING)
  FROM `archetypeid-staging.svy_stg.abr_raw_k3`

  UNION ALL

  SELECT
    'drop-002',
    CAST(archetype_id AS STRING),
    'K9',
    CAST(archetype_gender AS STRING),
    CAST(archetype_age_range AS STRING),
    CAST(archetype_race AS STRING),
    CAST(archetype_location_type AS STRING),
    CAST(archetype_adoption_category_name AS STRING),
    CAST(archetype_children_status AS STRING)
  FROM `archetypeid-staging.svy_stg.abr_raw_k9`
)

SELECT
  study_id,
  respondent_id,
  sample_arm,

  -- panel labels used as W-Tabs column headers
  CASE sample_arm
    WHEN 'K3' THEN '4-6'
    WHEN 'K9' THEN '7-12'
    WHEN 'HTR' THEN '12-64'
  END AS panel_label,

  CASE
    WHEN LOWER(TRIM(gender_raw)) IN ('male', 'm') THEN 'Men'
    WHEN LOWER(TRIM(gender_raw)) IN ('female', 'f') THEN 'Women'
    ELSE NULLIF(INITCAP(LOWER(TRIM(gender_raw))), '')
  END AS gender_banner,

  -- age for cuts
  SAFE_CAST(REGEXP_EXTRACT(TRIM(age_raw), r'^(\d+)') AS INT64) AS age_num,
  NULLIF(TRIM(age_raw), '') AS age_raw,

  -- kids sub-bands (W-Tabs quadrants for 4-6 / 7-9 / 10-12)
  CASE
    WHEN sample_arm = 'K3' THEN '4-6'
    WHEN sample_arm = 'K9'
      AND SAFE_CAST(REGEXP_EXTRACT(TRIM(age_raw), r'^(\d+)') AS INT64) BETWEEN 7 AND 9
      THEN '7-9'
    WHEN sample_arm = 'K9'
      AND SAFE_CAST(REGEXP_EXTRACT(TRIM(age_raw), r'^(\d+)') AS INT64) BETWEEN 10 AND 12
      THEN '10-12'
    WHEN sample_arm = 'HTR'
      AND SAFE_CAST(REGEXP_EXTRACT(TRIM(age_raw), r'^(\d+)') AS INT64) < 35
      THEN 'HTR <35'
    WHEN sample_arm = 'HTR'
      AND SAFE_CAST(REGEXP_EXTRACT(TRIM(age_raw), r'^(\d+)') AS INT64) >= 35
      THEN 'HTR 35+'
    ELSE NULL
  END AS age_band_cut,

  CASE
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(race_raw, '')), r'lati[nc]o|hispanic') THEN 'Latino / Hispanic'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(race_raw, '')), r'black|african') THEN 'Black / African American'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(race_raw, '')), r'white|caucasian') THEN 'White / Caucasian'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(race_raw, '')), r'asian|pacific') THEN 'Asian or Pacific Islander'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(race_raw, '')), r'two or more|mixed|multiracial') THEN 'Two or more races'
    WHEN NULLIF(TRIM(race_raw), '') IS NULL THEN NULL
    ELSE TRIM(race_raw)
  END AS ethnicity,

  CASE
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(location_type_raw, '')), r'suburban') THEN 'Suburban'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(location_type_raw, '')), r'urban') THEN 'Urban'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(location_type_raw, '')), r'rural') THEN 'Rural'
    WHEN REGEXP_CONTAINS(LOWER(IFNULL(location_type_raw, '')), r'exurban') THEN 'Exurban'
    WHEN NULLIF(TRIM(location_type_raw), '') IS NULL THEN NULL
    ELSE TRIM(location_type_raw)
  END AS location_type,

  NULLIF(TRIM(adoption_raw), '') AS adoption,
  NULLIF(TRIM(children_status_raw), '') AS children_status
FROM raw
;

-- Smoke
SELECT sample_arm, gender_banner, ethnicity, location_type, age_band_cut, adoption,
       COUNT(*) AS n
FROM `archetypeid-staging.svy.abr_respondent_meta`
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY 1, 6, 2
LIMIT 80;
