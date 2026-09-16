-- Kids banner: K3 (4-6) vs K9 (7-12) + TOP/T2B/BOTTOM per panel where signed.
-- House rule: FORMAT('%.1f'); empty → 0.0%

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_abr_kids_pcnt` AS

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
    AND cut_value IN ('K3', 'K9')
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
    AND s.cut_id = 'arm'
    AND s.cut_value IN ('K3', 'K9')
),

fmt AS (
  SELECT
    table_num, question_code, question_text, stub_sort, stub_kind, stub_label, cut_value,
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
    IFNULL(MAX(IF(cut_value = 'K3', cell, NULL)), '0.0%') AS age_4_6,
    IFNULL(MAX(IF(cut_value = 'K9', cell, NULL)), '0.0%') AS age_7_12
  FROM fmt
  GROUP BY table_num, stub_sort, stub_label
),

boxes AS (
  SELECT
    q.table_num,
    b.sample_arm,
    b.box_kind,
    b.pct_1dp
  FROM `archetypeid-staging.svy.mart_abr_boxes` AS b
  INNER JOIN questions AS q
    ON b.question_code = q.question_code
   AND IFNULL(b.question_text, '') = IFNULL(q.question_text, '')
  WHERE b.cut_id = 'arm'
    AND b.sample_arm IN ('K3', 'K9')
),

box_wide AS (
  SELECT
    table_num,
    IFNULL(MAX(IF(sample_arm = 'K3' AND box_kind = 'TOP BOX', pct_1dp, NULL)), '0.0%') AS k3_top,
    IFNULL(MAX(IF(sample_arm = 'K3' AND box_kind = 'T2B', pct_1dp, NULL)), '0.0%') AS k3_t2b,
    IFNULL(MAX(IF(sample_arm = 'K3' AND box_kind = 'BOTTOM BOX', pct_1dp, NULL)), '0.0%') AS k3_bot,
    IFNULL(MAX(IF(sample_arm = 'K9' AND box_kind = 'TOP BOX', pct_1dp, NULL)), '0.0%') AS k9_top,
    IFNULL(MAX(IF(sample_arm = 'K9' AND box_kind = 'T2B', pct_1dp, NULL)), '0.0%') AS k9_t2b,
    IFNULL(MAX(IF(sample_arm = 'K9' AND box_kind = 'BOTTOM BOX', pct_1dp, NULL)), '0.0%') AS k9_bot
  FROM boxes
  GROUP BY table_num
),

headers AS (
  SELECT q.table_num, h.*
  FROM questions AS q
  CROSS JOIN UNNEST([
    STRUCT(-100 AS sort_key, '#page' AS stub_label,
      CAST(NULL AS STRING) AS age_4_6, CAST(NULL AS STRING) AS age_7_12,
      CAST(NULL AS STRING) AS k3_top, CAST(NULL AS STRING) AS k3_t2b, CAST(NULL AS STRING) AS k3_bot,
      CAST(NULL AS STRING) AS k9_top, CAST(NULL AS STRING) AS k9_t2b, CAST(NULL AS STRING) AS k9_bot),
    STRUCT(-99, CONCAT('Table ', CAST(q.table_num AS STRING)),
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-98, q.question_text, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-97, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-96, 'Base: K3 (4-6) vs K9 (7-12)', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-95, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-94, '', '4-6', '7-12', 'K3 TOP', 'K3 T2B', 'K3 BOT', 'K9 TOP', 'K9 T2B', 'K9 BOT'),
    STRUCT(-93, '', 'K3', 'K9', '', '', '', '', '', ''),
    STRUCT(-92, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ]) AS h
),

body AS (
  SELECT
    w.table_num,
    w.stub_sort,
    w.stub_label,
    w.age_4_6,
    w.age_7_12,
    IF(w.stub_label = 'Total', b.k3_top, CAST(NULL AS STRING)) AS k3_top,
    IF(w.stub_label = 'Total', b.k3_t2b, CAST(NULL AS STRING)) AS k3_t2b,
    IF(w.stub_label = 'Total', b.k3_bot, CAST(NULL AS STRING)) AS k3_bot,
    IF(w.stub_label = 'Total', b.k9_top, CAST(NULL AS STRING)) AS k9_top,
    IF(w.stub_label = 'Total', b.k9_t2b, CAST(NULL AS STRING)) AS k9_t2b,
    IF(w.stub_label = 'Total', b.k9_bot, CAST(NULL AS STRING)) AS k9_bot
  FROM wide AS w
  LEFT JOIN box_wide AS b USING (table_num)
)

SELECT
  stub_label,
  age_4_6,
  age_7_12,
  k3_top, k3_t2b, k3_bot,
  k9_top, k9_t2b, k9_bot
FROM (
  SELECT table_num, sort_key AS stub_sort, stub_label,
         age_4_6, age_7_12, k3_top, k3_t2b, k3_bot, k9_top, k9_t2b, k9_bot
  FROM headers
  UNION ALL
  SELECT table_num, stub_sort, stub_label,
         age_4_6, age_7_12, k3_top, k3_t2b, k3_bot, k9_top, k9_t2b, k9_bot
  FROM body
)
ORDER BY table_num, stub_sort;
