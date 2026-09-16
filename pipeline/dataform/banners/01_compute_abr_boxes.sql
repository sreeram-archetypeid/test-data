-- Compute TOP BOX / T2B / BOTTOM BOX from mart_stubs option rows.
-- Prereq: run config/abr_box_defs.sql first.
-- House rule: percentages FORMAT('%.1f', …); missing → 0.0%

CREATE OR REPLACE TABLE `archetypeid-staging.svy.mart_abr_boxes` AS

WITH opts AS (
  SELECT
    s.study_id,
    s.question_code,
    s.question_text,
    s.cut_id,
    s.cut_value,
    -- strip Arena-style prefixes so labels match abr_box_defs
    REGEXP_REPLACE(
      REGEXP_REPLACE(TRIM(s.stub_label), r'^\d+\.\s*\d+\.\s*', ''),
      r'^\d+\.\s*', ''
    ) AS stub_label,
    s.count_value,
    s.n_base
  FROM `archetypeid-staging.svy.mart_stubs` AS s
  WHERE s.study_id = 'drop-002'
    AND s.stub_kind NOT IN ('base', 'sigma', 'net')
    AND s.cut_id IN ('arm', 'total', 'gender', 'arm_gender')
),

mapped AS (
  SELECT
    o.*,
    q.scale_id,
    -- for arm cuts, sample_arm is cut_value; else join all arms' defs via arm from cut
    CASE
      WHEN o.cut_id = 'arm' THEN o.cut_value
      WHEN o.cut_id = 'arm_gender' THEN REGEXP_EXTRACT(o.cut_value, r'^(HTR|K3|K9)')
      ELSE CAST(NULL AS STRING)
    END AS sample_arm_from_cut
  FROM opts AS o
  INNER JOIN `archetypeid-staging.svy_config.abr_question_boxes` AS q
    ON REGEXP_CONTAINS(o.question_text, q.question_regex)
   AND (q.sample_arm IS NULL OR q.sample_arm = CASE
          WHEN o.cut_id = 'arm' THEN o.cut_value
          WHEN o.cut_id = 'arm_gender' THEN REGEXP_EXTRACT(o.cut_value, r'^(HTR|K3|K9)')
          ELSE q.sample_arm  -- allow HTR-wide when cut is total/gender (HTR-only questions)
        END)
),

-- For total/gender cuts on HTR-only questions, force sample_arm = HTR when scale is HTR family
mapped2 AS (
  SELECT
    study_id, question_code, question_text, cut_id, cut_value,
    stub_label, count_value, n_base, scale_id,
    COALESCE(
      sample_arm_from_cut,
      IF(scale_id LIKE 'k3_%', 'K3',
        IF(scale_id LIKE 'k9_%', 'K9', 'HTR'))
    ) AS sample_arm
  FROM mapped
),

joined AS (
  SELECT
    m.study_id,
    m.question_code,
    m.question_text,
    m.cut_id,
    m.cut_value,
    m.sample_arm,
    m.scale_id,
    d.box_kind,
    m.n_base,
    m.count_value
  FROM mapped2 AS m
  INNER JOIN `archetypeid-staging.svy_config.abr_box_defs` AS d
    ON m.scale_id = d.scale_id
   AND m.sample_arm = d.sample_arm
   AND m.stub_label IN UNNEST(d.option_labels)
),

agg AS (
  SELECT
    study_id,
    question_code,
    question_text,
    cut_id,
    cut_value,
    sample_arm,
    scale_id,
    box_kind,
    ANY_VALUE(n_base) AS n_base,
    SUM(count_value) AS n_box
  FROM joined
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
)

SELECT
  study_id,
  question_code,
  question_text,
  cut_id,
  cut_value,
  sample_arm,
  scale_id,
  box_kind,
  n_base,
  n_box,
  SAFE_DIVIDE(n_box, n_base) AS pct_value,
  CONCAT(FORMAT('%.1f', IFNULL(SAFE_DIVIDE(n_box, n_base), 0) * 100), '%') AS pct_1dp
FROM agg
;

-- Smoke: boxes for kids trailer-like on arm cuts
SELECT
  sample_arm,
  box_kind,
  pct_1dp,
  n_box,
  n_base,
  LEFT(question_text, 50) AS q
FROM `archetypeid-staging.svy.mart_abr_boxes`
WHERE cut_id = 'arm'
  AND REGEXP_CONTAINS(question_text, r'(?i)like the trailer')
ORDER BY sample_arm, box_kind;
