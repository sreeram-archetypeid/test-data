-- HTR-only banner: Total arm + gender + TOP/T2B/BOTTOM where signed.
-- House rule: FORMAT('%.1f'); empty → 0.0%

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_abr_htr_pcnt` AS

WITH questions AS (
  SELECT
    question_code,
    question_text,
    DENSE_RANK() OVER (
      ORDER BY SAFE_CAST(REGEXP_EXTRACT(question_code, r'(\d+)') AS INT64), question_text
    ) AS table_num
  FROM `archetypeid-staging.svy.mart_stubs`
  WHERE study_id = 'drop-002'
    AND cut_id = 'arm'
    AND cut_value = 'HTR'
    AND stub_kind = 'base'
  GROUP BY question_code, question_text
),

src AS (
  SELECT
    q.table_num,
    s.question_code,
    s.question_text,
    s.stub_kind,
    s.stub_sort,
    REGEXP_REPLACE(
      REGEXP_REPLACE(s.stub_label, r'^\d+\.\s*\d+\.\s*', ''),
      r'^\d+\.\s*', ''
    ) AS stub_label,
    s.cut_id,
    s.cut_value,
    s.count_value,
    s.pct_value
  FROM `archetypeid-staging.svy.mart_stubs` AS s
  INNER JOIN questions AS q
    ON s.question_code = q.question_code
   AND IFNULL(s.question_text, '') = IFNULL(q.question_text, '')
  WHERE s.study_id = 'drop-002'
    AND (
      (s.cut_id = 'arm' AND s.cut_value = 'HTR')
      OR (s.cut_id = 'arm_gender' AND s.cut_value IN ('HTR · Men', 'HTR · Women'))
    )
),

fmt AS (
  SELECT
    table_num, question_code, question_text, stub_sort, stub_kind, stub_label, cut_id, cut_value,
    CASE
      WHEN stub_kind = 'base' THEN CAST(count_value AS STRING)
      WHEN stub_kind = 'sigma' THEN '100.0%'
      ELSE CONCAT(FORMAT('%.1f', IFNULL(pct_value, 0) * 100), '%')
    END AS cell
  FROM src
),

wide AS (
  SELECT
    table_num,
    ANY_VALUE(question_code) AS question_code,
    ANY_VALUE(question_text) AS question_text,
    stub_sort,
    stub_label,
    IFNULL(MAX(IF(cut_id = 'arm' AND cut_value = 'HTR', cell, NULL)), '0.0%') AS htr,
    IFNULL(MAX(IF(cut_value = 'HTR · Men', cell, NULL)), '0.0%') AS htr_men,
    IFNULL(MAX(IF(cut_value = 'HTR · Women', cell, NULL)), '0.0%') AS htr_women
  FROM fmt
  GROUP BY table_num, stub_sort, stub_label
),

-- attach boxes on HTR arm cut
boxes AS (
  SELECT
    q.table_num,
    b.box_kind,
    b.pct_1dp
  FROM `archetypeid-staging.svy.mart_abr_boxes` AS b
  INNER JOIN questions AS q
    ON b.question_code = q.question_code
   AND IFNULL(b.question_text, '') = IFNULL(q.question_text, '')
  WHERE b.cut_id = 'arm'
    AND b.cut_value = 'HTR'
),

box_wide AS (
  SELECT
    table_num,
    IFNULL(MAX(IF(box_kind = 'TOP BOX', pct_1dp, NULL)), '0.0%') AS top_box,
    IFNULL(MAX(IF(box_kind = 'T2B', pct_1dp, NULL)), '0.0%') AS t2b,
    IFNULL(MAX(IF(box_kind = 'BOTTOM BOX', pct_1dp, NULL)), '0.0%') AS bottom_box
  FROM boxes
  GROUP BY table_num
),

headers AS (
  SELECT q.table_num, h.*
  FROM questions AS q
  CROSS JOIN UNNEST([
    STRUCT(-100 AS sort_key, '#page' AS stub_label,
      CAST(NULL AS STRING) AS htr, CAST(NULL AS STRING) AS htr_men, CAST(NULL AS STRING) AS htr_women,
      CAST(NULL AS STRING) AS top_box, CAST(NULL AS STRING) AS t2b, CAST(NULL AS STRING) AS bottom_box),
    STRUCT(-99, CONCAT('Table ', CAST(q.table_num AS STRING)), NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-98, q.question_text, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-97, '', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-96, 'Base: HTR (12-64)', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-95, '', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-94, '', 'HTR', 'HTR · Men', 'HTR · Women', 'TOP BOX', 'T2B', 'BOTTOM BOX'),
    STRUCT(-93, '', '12-64', 'Men', 'Women', '', '', ''),
    STRUCT(-92, '', NULL, NULL, NULL, NULL, NULL, NULL)
  ]) AS h
),

body AS (
  SELECT
    w.table_num,
    w.stub_sort,
    w.stub_label,
    w.htr,
    w.htr_men,
    w.htr_women,
    IF(w.stub_label = 'Total', b.top_box, CAST(NULL AS STRING)) AS top_box,
    IF(w.stub_label = 'Total', b.t2b, CAST(NULL AS STRING)) AS t2b,
    IF(w.stub_label = 'Total', b.bottom_box, CAST(NULL AS STRING)) AS bottom_box
  FROM wide AS w
  LEFT JOIN box_wide AS b USING (table_num)
  WHERE w.htr IS NOT NULL OR w.stub_label IN ('Total', 'SIGMA')
)

SELECT stub_label, htr, htr_men, htr_women, top_box, t2b, bottom_box
FROM (
  SELECT table_num, sort_key AS stub_sort, stub_label, htr, htr_men, htr_women, top_box, t2b, bottom_box
  FROM headers
  UNION ALL
  SELECT table_num, stub_sort, stub_label, htr, htr_men, htr_women, top_box, t2b, bottom_box
  FROM body
)
ORDER BY table_num, stub_sort;
