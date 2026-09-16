-- Long W-Tabs-style ABR banner mart (tidy).
-- One row per question × option/base/sigma × banner_group × banner_cut × panel.
-- House rule: pct via FORMAT('%.1f'); missing later filled as 0.0% in renders.
-- Prereq: mart_stubs + abr_respondent_meta for drop-002.

CREATE OR REPLACE TABLE `archetypeid-staging.svy.mart_abr_banner_meta` AS

WITH people AS (
  SELECT * FROM `archetypeid-staging.svy.abr_respondent_meta`
  WHERE study_id = 'drop-002'
),

-- closed-ended answers from fct (SELECT + SCALE)
answers AS (
  SELECT
    f.study_id,
    f.respondent_id,
    f.question_code,
    f.question_text,
    f.tabulation_kind,
    REGEXP_REPLACE(
      REGEXP_REPLACE(TRIM(f.option_value), r'^\d+\.\s*\d+\.\s*', ''),
      r'^\d+\.\s*', ''
    ) AS stub_label
  FROM `archetypeid-staging.svy.fct_response` AS f
  WHERE f.study_id = 'drop-002'
    AND f.tabulation_kind IN ('SELECT', 'SCALE')
    AND f.option_value IS NOT NULL
    AND TRIM(f.option_value) != ''
),

joined AS (
  SELECT
    a.*,
    p.sample_arm,
    p.panel_label,
    p.gender_banner,
    p.ethnicity,
    p.location_type,
    p.adoption,
    p.children_status,
    p.age_band_cut
  FROM answers AS a
  INNER JOIN people AS p
    USING (study_id, respondent_id)
),

-- explode banner cuts
cuts AS (
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'TOTAL' AS banner_group, 'Total' AS banner_cut
  FROM joined

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'PANEL', panel_label
  FROM joined
  WHERE panel_label IS NOT NULL

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'GENDER', gender_banner
  FROM joined
  WHERE gender_banner IS NOT NULL

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'ETHNICITY', ethnicity
  FROM joined
  WHERE ethnicity IS NOT NULL

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'LOCATION', location_type
  FROM joined
  WHERE location_type IS NOT NULL

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'ADOPTION', adoption
  FROM joined
  WHERE adoption IS NOT NULL

  UNION ALL
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'AGE_BAND', age_band_cut
  FROM joined
  WHERE age_band_cut IS NOT NULL

  UNION ALL
  -- gender × panel (Men/Women within 4-6, 7-12, 12-64)
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'PANEL_GENDER', CONCAT(panel_label, ' · ', gender_banner)
  FROM joined
  WHERE panel_label IS NOT NULL AND gender_banner IS NOT NULL

  UNION ALL
  -- kids/HTR age-band × gender (W-Tabs quadrants)
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'QUADRANTS', CONCAT(gender_banner, ' · ', age_band_cut)
  FROM joined
  WHERE gender_banner IS NOT NULL AND age_band_cut IS NOT NULL

  UNION ALL
  -- HTR-only children status
  SELECT study_id, respondent_id, question_code, question_text, tabulation_kind,
         stub_label, sample_arm, panel_label,
         'CHILDREN', children_status
  FROM joined
  WHERE sample_arm = 'HTR' AND children_status IS NOT NULL
),

bases AS (
  SELECT
    study_id, question_code, question_text, sample_arm, panel_label,
    banner_group, banner_cut,
    COUNT(DISTINCT respondent_id) AS n_base
  FROM cuts
  GROUP BY 1, 2, 3, 4, 5, 6, 7
),

option_counts AS (
  SELECT
    study_id, question_code, question_text, sample_arm, panel_label,
    banner_group, banner_cut, stub_label,
    COUNT(DISTINCT respondent_id) AS n_opt
  FROM cuts
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),

assembled AS (
  -- base
  SELECT
    b.study_id, b.question_code, b.question_text, b.sample_arm, b.panel_label,
    b.banner_group, b.banner_cut,
    'base' AS stub_kind,
    'Total' AS stub_label,
    0 AS stub_sort,
    b.n_base,
    b.n_base AS n_value,
    CAST(NULL AS FLOAT64) AS pct_value
  FROM bases AS b

  UNION ALL

  -- options
  SELECT
    o.study_id, o.question_code, o.question_text, o.sample_arm, o.panel_label,
    o.banner_group, o.banner_cut,
    'option' AS stub_kind,
    o.stub_label,
    ROW_NUMBER() OVER (
      PARTITION BY o.study_id, o.question_code, o.question_text, o.sample_arm,
                   o.banner_group, o.banner_cut
      ORDER BY o.n_opt DESC, o.stub_label
    ) AS stub_sort,
    b.n_base,
    o.n_opt AS n_value,
    SAFE_DIVIDE(o.n_opt, b.n_base) AS pct_value
  FROM option_counts AS o
  INNER JOIN bases AS b
    USING (study_id, question_code, question_text, sample_arm, panel_label, banner_group, banner_cut)

  UNION ALL

  -- sigma
  SELECT
    b.study_id, b.question_code, b.question_text, b.sample_arm, b.panel_label,
    b.banner_group, b.banner_cut,
    'sigma' AS stub_kind,
    'SIGMA' AS stub_label,
    999 AS stub_sort,
    b.n_base,
    b.n_base AS n_value,
    1.0 AS pct_value
  FROM bases AS b
)

SELECT
  study_id,
  question_code,
  question_text,
  sample_arm,
  panel_label,
  banner_group,
  banner_cut,
  stub_kind,
  stub_label,
  stub_sort,
  n_base,
  n_value,
  pct_value,
  CASE
    WHEN stub_kind = 'base' THEN CAST(n_value AS STRING)
    WHEN stub_kind = 'sigma' THEN '100.0%'
    ELSE CONCAT(FORMAT('%.1f', IFNULL(pct_value, 0) * 100), '%')
  END AS cell_1dp
FROM assembled
;

-- Smoke: trailer-like × meta groups
SELECT banner_group, banner_cut, panel_label, stub_kind, stub_label, cell_1dp, n_base
FROM `archetypeid-staging.svy.mart_abr_banner_meta`
WHERE REGEXP_CONTAINS(question_text, r'(?i)like the trailer')
  AND stub_kind IN ('base', 'option')
  AND banner_group IN ('PANEL', 'GENDER', 'ETHNICITY')
ORDER BY banner_group, panel_label, banner_cut, stub_sort
LIMIT 60;
