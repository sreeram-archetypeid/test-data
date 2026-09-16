-- Drop-001 G/S Ban1 Pcnt — same structure as morning working export.
-- Prereq: Dataform run with study_id=drop-001, format_id=arena_ff_v1
-- and mart_stubs has arm / arm_quadrants cuts.

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_ban1_gs_pcnt` AS

WITH qq AS (
  SELECT
    study_id,
    question_code,
    question_text,
    DENSE_RANK() OVER (
      PARTITION BY study_id
      ORDER BY SAFE_CAST(REGEXP_EXTRACT(question_code, r'(\d+)') AS INT64), question_text
    ) AS table_num
  FROM `archetypeid-staging.svy.mart_stubs`
  WHERE study_id = 'drop-001'
    AND stub_kind = 'base'
    AND cut_id = 'total'
),

q_kind AS (
  SELECT
    study_id,
    question_code,
    question_text,
    MAX(IF(stub_kind = 'net', 1, 0)) AS is_scale
  FROM `archetypeid-staging.svy.mart_stubs`
  WHERE study_id = 'drop-001'
  GROUP BY 1, 2, 3
),

fmt AS (
  SELECT
    s.study_id,
    qq.table_num,
    s.question_code,
    s.question_text,
    s.stub_kind,
    s.stub_label,
    s.stub_sort,
    s.cut_id,
    s.cut_value,
    s.n_base,
    s.count_value,
    s.pct_value,
    k.is_scale,
    CASE
      WHEN s.stub_kind = 'base' THEN CAST(s.n_base AS STRING)
      WHEN s.stub_kind = 'sigma' AND k.is_scale = 0 THEN CAST(NULL AS STRING)
      WHEN s.stub_kind = 'sigma' THEN '100'
      ELSE IFNULL(FORMAT('%.0f', s.pct_value * 100), '0')
    END AS cell_pcnt
  FROM `archetypeid-staging.svy.mart_stubs` AS s
  INNER JOIN qq
    ON s.study_id = qq.study_id
   AND s.question_code = qq.question_code
   AND IFNULL(s.question_text, '') = IFNULL(qq.question_text, '')
  INNER JOIN q_kind AS k
    ON s.study_id = k.study_id
   AND s.question_code = k.question_code
   AND IFNULL(s.question_text, '') = IFNULL(k.question_text, '')
  WHERE s.study_id = 'drop-001'
    AND (
      (s.cut_id = 'total' AND s.cut_value = 'Total')
      OR (s.cut_id = 'arm' AND s.cut_value IN ('G', 'S'))
      OR (s.cut_id = 'arm_gender' AND s.cut_value IN (
            'G · Men', 'G · Women', 'S · Men', 'S · Women'))
      OR (s.cut_id = 'arm_quadrants' AND s.cut_value IN (
            'G · Men <35', 'G · Men 35+', 'G · Women <35', 'G · Women 35+',
            'S · Men <35', 'S · Men 35+', 'S · Women <35', 'S · Women 35+'))
    )
),

piv AS (
  SELECT
    study_id, table_num, question_code, question_text,
    stub_kind, stub_label, stub_sort, is_scale,
    MAX(IF(cut_id = 'total' AND cut_value = 'Total', cell_pcnt, NULL)) AS c_total,
    MAX(IF(cut_id = 'arm' AND cut_value = 'G', cell_pcnt, NULL)) AS c_g,
    MAX(IF(cut_id = 'arm' AND cut_value = 'S', cell_pcnt, NULL)) AS c_s,
    MAX(IF(cut_id = 'arm_gender' AND cut_value = 'G · Men', cell_pcnt, NULL)) AS c_g_men,
    MAX(IF(cut_id = 'arm_gender' AND cut_value = 'G · Women', cell_pcnt, NULL)) AS c_g_women,
    MAX(IF(cut_id = 'arm_gender' AND cut_value = 'S · Men', cell_pcnt, NULL)) AS c_s_men,
    MAX(IF(cut_id = 'arm_gender' AND cut_value = 'S · Women', cell_pcnt, NULL)) AS c_s_women,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'G · Men <35', cell_pcnt, NULL)) AS c_g_men_lt35,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'G · Men 35+', cell_pcnt, NULL)) AS c_g_men_35p,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'G · Women <35', cell_pcnt, NULL)) AS c_g_women_lt35,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'G · Women 35+', cell_pcnt, NULL)) AS c_g_women_35p,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'S · Men <35', cell_pcnt, NULL)) AS c_s_men_lt35,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'S · Men 35+', cell_pcnt, NULL)) AS c_s_men_35p,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'S · Women <35', cell_pcnt, NULL)) AS c_s_women_lt35,
    MAX(IF(cut_id = 'arm_quadrants' AND cut_value = 'S · Women 35+', cell_pcnt, NULL)) AS c_s_women_35p
  FROM fmt
  WHERE NOT (stub_kind = 'sigma' AND is_scale = 0)
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
),

hdr AS (
  SELECT
    study_id, table_num, question_code, question_text,
    -20 AS stub_sort, 'hdr1' AS row_kind, CAST(NULL AS STRING) AS stub_label,
    '' AS c_total, 'G' AS c_g, 'S' AS c_s,
    'G' AS c_g_men, 'G' AS c_g_women, 'S' AS c_s_men, 'S' AS c_s_women,
    'G' AS c_g_men_lt35, 'G' AS c_g_men_35p, 'G' AS c_g_women_lt35, 'G' AS c_g_women_35p,
    'S' AS c_s_men_lt35, 'S' AS c_s_men_35p, 'S' AS c_s_women_lt35, 'S' AS c_s_women_35p
  FROM qq
  UNION ALL
  SELECT
    study_id, table_num, question_code, question_text,
    -10, 'hdr2', NULL,
    'Total', 'Total', 'Total',
    'Men', 'Women', 'Men', 'Women',
    'Men <35', 'Men 35+', 'Women <35', 'Women 35+',
    'Men <35', 'Men 35+', 'Women <35', 'Women 35+'
  FROM qq
),

body AS (
  SELECT
    study_id, table_num, question_code, question_text,
    stub_sort,
    stub_kind AS row_kind,
    CASE
      WHEN stub_kind = 'base' THEN 'Base'
      WHEN stub_kind = 'sigma' THEN 'SIGMA'
      ELSE stub_label
    END AS stub_label,
    IFNULL(c_total, '0') AS c_total,
    IFNULL(c_g, '0') AS c_g,
    IFNULL(c_s, '0') AS c_s,
    IFNULL(c_g_men, '0') AS c_g_men,
    IFNULL(c_g_women, '0') AS c_g_women,
    IFNULL(c_s_men, '0') AS c_s_men,
    IFNULL(c_s_women, '0') AS c_s_women,
    IFNULL(c_g_men_lt35, '0') AS c_g_men_lt35,
    IFNULL(c_g_men_35p, '0') AS c_g_men_35p,
    IFNULL(c_g_women_lt35, '0') AS c_g_women_lt35,
    IFNULL(c_g_women_35p, '0') AS c_g_women_35p,
    IFNULL(c_s_men_lt35, '0') AS c_s_men_lt35,
    IFNULL(c_s_men_35p, '0') AS c_s_men_35p,
    IFNULL(c_s_women_lt35, '0') AS c_s_women_lt35,
    IFNULL(c_s_women_35p, '0') AS c_s_women_35p
  FROM piv
)

SELECT
  study_id,
  table_num,
  CONCAT('#', CAST(table_num AS STRING)) AS page,
  CONCAT('Table ', CAST(table_num AS STRING)) AS table_label,
  question_code,
  TRIM(question_text, '"') AS question_text,
  row_kind,
  stub_label,
  stub_sort,
  c_total AS Total,
  c_g AS G,
  c_s AS S,
  c_g_men AS G_Men,
  c_g_women AS G_Women,
  c_s_men AS S_Men,
  c_s_women AS S_Women,
  c_g_men_lt35 AS G_Men_lt35,
  c_g_men_35p AS G_Men_35p,
  c_g_women_lt35 AS G_Women_lt35,
  c_g_women_35p AS G_Women_35p,
  c_s_men_lt35 AS S_Men_lt35,
  c_s_men_35p AS S_Men_35p,
  c_s_women_lt35 AS S_Women_lt35,
  c_s_women_35p AS S_Women_35p
FROM (
  SELECT * FROM hdr
  UNION ALL
  SELECT * FROM body
)
ORDER BY table_num, stub_sort, stub_label;
