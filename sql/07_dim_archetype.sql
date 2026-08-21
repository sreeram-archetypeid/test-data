-- One row per persona (398).
--
-- IMPORTANT: the 46 attribute columns are projected INSIDE each UNION arm.
-- raw_read_s22 and raw_read_s23 carry 291 and 298 data columns, so a
-- `SELECT * EXCEPT(...) UNION DISTINCT` across them cannot bind. Projecting
-- first equalises the arity and makes the UNION DISTINCT meaningful.
CREATE OR REPLACE TABLE `ff_20_curated.dim_archetype`
CLUSTER BY creative, cohort_code AS
WITH attrs AS (
  SELECT
    archetype_id,
    group_name,
    sample_name,
    archetype_title,
    archetype_name,
    archetype_age_range,
    archetype_gender,
    archetype_race,
    archetype_marital_status,
    archetype_children_status,
    archetype_children,
    archetype_education_level,
    archetype_field_of_study,
    archetype_occupation,
    archetype_income_range,
    archetype_political_affiliation,
    archetype_religious_affiliation,
    archetype_location,
    archetype_location_type,
    archetype_hobbies_and_interests,
    archetype_lived_experience,
    archetype_nps_score,
    archetype_persona_summary,
    archetype_goals_and_motivations,
    archetype_audience_insights_triggers,
    archetype_psychographic_values,
    archetype_psychographic_interests,
    archetype_psychographic_lifestyle,
    archetype_purchasing_behaviors,
    archetype_challenges_pain_points,
    archetype_decision_making_steps,
    archetype_triggers_to_switch,
    archetype_product_expectations,
    archetype_product_influencers,
    archetype_media_channels,
    archetype_psychometric_vector_name,
    archetype_psychometric_vector_summary,
    archetype_psychometric_vector_characteristics,
    archetype_psychometric_vector_emotions,
    archetype_why_psychometric_vector_fits,
    archetype_group_dynamics,
    archetype_adoption_category_name,
    archetype_adoption_rationale,
    archetype_composite_attitude_score_summary,
    archetype_nps_summary,
    archetype_lived_experience_summary
  FROM `ff_00_raw.raw_read_s22`
  UNION DISTINCT
  SELECT
    archetype_id,
    group_name,
    sample_name,
    archetype_title,
    archetype_name,
    archetype_age_range,
    archetype_gender,
    archetype_race,
    archetype_marital_status,
    archetype_children_status,
    archetype_children,
    archetype_education_level,
    archetype_field_of_study,
    archetype_occupation,
    archetype_income_range,
    archetype_political_affiliation,
    archetype_religious_affiliation,
    archetype_location,
    archetype_location_type,
    archetype_hobbies_and_interests,
    archetype_lived_experience,
    archetype_nps_score,
    archetype_persona_summary,
    archetype_goals_and_motivations,
    archetype_audience_insights_triggers,
    archetype_psychographic_values,
    archetype_psychographic_interests,
    archetype_psychographic_lifestyle,
    archetype_purchasing_behaviors,
    archetype_challenges_pain_points,
    archetype_decision_making_steps,
    archetype_triggers_to_switch,
    archetype_product_expectations,
    archetype_product_influencers,
    archetype_media_channels,
    archetype_psychometric_vector_name,
    archetype_psychometric_vector_summary,
    archetype_psychometric_vector_characteristics,
    archetype_psychometric_vector_emotions,
    archetype_why_psychometric_vector_fits,
    archetype_group_dynamics,
    archetype_adoption_category_name,
    archetype_adoption_rationale,
    archetype_composite_attitude_score_summary,
    archetype_nps_summary,
    archetype_lived_experience_summary
  FROM `ff_00_raw.raw_read_s23`
)
SELECT
  a.*,
  'READ' AS modality,
  CASE WHEN REGEXP_CONTAINS(group_name, r'-G-') THEN 'Goyer'
       WHEN REGEXP_CONTAINS(group_name, r'-S-') THEN 'Sheridan' END AS creative,
  CONCAT(
    CASE WHEN REGEXP_CONTAINS(group_name, r'-G-') THEN 'G' ELSE 'S' END,
    '.', REGEXP_EXTRACT(group_name, r'\.(\d)$')
  ) AS cohort_code,

  -- D5 gender case drift
  INITCAP(TRIM(archetype_gender)) AS gender_clean,

  -- D4 age. Never overwrite age_raw.
  archetype_age_range AS age_raw,
  SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})(?:\s|$|\s*\()') AS INT64)
    AS age_exact,
  CASE
    WHEN REGEXP_CONTAINS(archetype_age_range, r'^\d{1,2}(\s*\(|$)') THEN
      CASE
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 17 THEN '13-17'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 24 THEN '18-24'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 34 THEN '25-34'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 44 THEN '35-44'
        WHEN SAFE_CAST(REGEXP_EXTRACT(archetype_age_range, r'^(\d{1,2})') AS INT64) <= 54 THEN '45-54'
        ELSE '55-64' END
    WHEN archetype_age_range = '13-16' THEN '13-17'
    WHEN archetype_age_range = '17-24' THEN '18-24'   -- imputed, see D4
    WHEN archetype_age_range IN ('25-29','30-34') THEN '25-34'
    WHEN archetype_age_range IN ('35-39','40-44') THEN '35-44'
    WHEN archetype_age_range = '45-54' THEN '45-54'
    WHEN archetype_age_range = '55-64' THEN '55-64'
  END AS age_band_banner,
  (archetype_age_range = '17-24') AS age_band_is_imputed,

  -- D6 income: point values and ranges coexist
  SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'^\$([\d,]+)'), ',', '')
            AS INT64) AS income_low_usd,
  COALESCE(
    SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'-\s*\$([\d,]+)'), ',', '') AS INT64),
    SAFE_CAST(REGEXP_REPLACE(REGEXP_EXTRACT(archetype_income_range, r'^\$([\d,]+)'), ',', '') AS INT64)
  ) AS income_high_usd,

  -- D11 NPS is a string in source
  SAFE_CAST(archetype_nps_score AS INT64) AS nps_score,
  CASE WHEN SAFE_CAST(archetype_nps_score AS INT64) >= 9 THEN 'Promoter'
       WHEN SAFE_CAST(archetype_nps_score AS INT64) >= 7 THEN 'Passive'
       ELSE 'Detractor' END AS nps_band,

  (archetype_children_status != 'no_children') AS is_parent
FROM attrs a;
