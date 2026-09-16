-- Kids W-Tabs questionnaire book with meta banners.
-- Columns: 4-6 | 7-12 | Men/Women within panel | Ethnicity (major) | TOP/T2B/BOT per panel
-- Prereq: 01 boxes, 04 meta, 05 mart_abr_banner_meta

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_abr_kids_wtabs` AS

WITH questions AS (
  SELECT
    question_code,
    question_text,
    DENSE_RANK() OVER (
      ORDER BY SAFE_CAST(REGEXP_EXTRACT(question_code, r'(\d+)') AS INT64), question_text
    ) AS table_num
  FROM `archetypeid-staging.svy.mart_abr_banner_meta`
  WHERE study_id = 'drop-002'
    AND sample_arm IN ('K3', 'K9')
    AND banner_group = 'PANEL'
    AND stub_kind = 'base'
  GROUP BY question_code, question_text
),

src AS (
  SELECT
    q.table_num,
    m.question_text,
    m.stub_kind,
    m.stub_sort,
    m.stub_label,
    m.banner_group,
    m.banner_cut,
    m.panel_label,
    m.cell_1dp,
    m.n_base
  FROM `archetypeid-staging.svy.mart_abr_banner_meta` AS m
  INNER JOIN questions AS q
    ON m.question_code = q.question_code
   AND IFNULL(m.question_text, '') = IFNULL(q.question_text, '')
  WHERE m.study_id = 'drop-002'
    AND m.sample_arm IN ('K3', 'K9')
    AND (
      m.banner_group = 'PANEL'
      OR (m.banner_group = 'PANEL_GENDER' AND m.banner_cut IN (
            '4-6 · Men', '4-6 · Women', '7-12 · Men', '7-12 · Women'))
      OR (m.banner_group = 'ETHNICITY' AND m.banner_cut IN (
            'Latino / Hispanic', 'Black / African American',
            'White / Caucasian', 'Asian or Pacific Islander', 'Two or more races')
          AND m.panel_label IN ('4-6', '7-12'))
      OR (m.banner_group = 'AGE_BAND' AND m.banner_cut IN ('4-6', '7-9', '10-12'))
    )
),

wide AS (
  SELECT
    table_num,
    ANY_VALUE(question_text) AS question_text,
    stub_sort,
    stub_label,
    IFNULL(MAX(IF(banner_group = 'PANEL' AND banner_cut = '4-6', cell_1dp, NULL)), '0.0%') AS c_46,
    IFNULL(MAX(IF(banner_group = 'PANEL' AND banner_cut = '7-12', cell_1dp, NULL)), '0.0%') AS c_712,
    IFNULL(MAX(IF(banner_cut = '4-6 · Men', cell_1dp, NULL)), '0.0%') AS c_46_men,
    IFNULL(MAX(IF(banner_cut = '4-6 · Women', cell_1dp, NULL)), '0.0%') AS c_46_women,
    IFNULL(MAX(IF(banner_cut = '7-12 · Men', cell_1dp, NULL)), '0.0%') AS c_712_men,
    IFNULL(MAX(IF(banner_cut = '7-12 · Women', cell_1dp, NULL)), '0.0%') AS c_712_women,
    IFNULL(MAX(IF(banner_group = 'AGE_BAND' AND banner_cut = '7-9', cell_1dp, NULL)), '0.0%') AS c_79,
    IFNULL(MAX(IF(banner_group = 'AGE_BAND' AND banner_cut = '10-12', cell_1dp, NULL)), '0.0%') AS c_1012,
    -- ethnicity pooled kids (either panel) — use PANEL ethnicity by taking max across kids panels is wrong;
    -- instead show ethnicity within 7-12 (larger base) as primary kids ethnicity read
    IFNULL(MAX(IF(banner_group = 'ETHNICITY' AND panel_label = '7-12'
                  AND banner_cut = 'Latino / Hispanic', cell_1dp, NULL)), '0.0%') AS eth_lat_712,
    IFNULL(MAX(IF(banner_group = 'ETHNICITY' AND panel_label = '7-12'
                  AND banner_cut = 'Black / African American', cell_1dp, NULL)), '0.0%') AS eth_blk_712,
    IFNULL(MAX(IF(banner_group = 'ETHNICITY' AND panel_label = '7-12'
                  AND banner_cut = 'White / Caucasian', cell_1dp, NULL)), '0.0%') AS eth_wht_712
  FROM src
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
  WHERE b.cut_id = 'arm' AND b.sample_arm IN ('K3', 'K9')
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

hdr AS (
  SELECT q.table_num, x.*
  FROM questions AS q
  CROSS JOIN UNNEST([
    STRUCT(-100 AS sort_key, '#page' AS stub_label,
      CAST(NULL AS STRING) AS c_46, CAST(NULL AS STRING) AS c_712,
      CAST(NULL AS STRING) AS c_46_men, CAST(NULL AS STRING) AS c_46_women,
      CAST(NULL AS STRING) AS c_712_men, CAST(NULL AS STRING) AS c_712_women,
      CAST(NULL AS STRING) AS c_79, CAST(NULL AS STRING) AS c_1012,
      CAST(NULL AS STRING) AS eth_lat_712, CAST(NULL AS STRING) AS eth_blk_712, CAST(NULL AS STRING) AS eth_wht_712,
      CAST(NULL AS STRING) AS k3_top, CAST(NULL AS STRING) AS k3_t2b, CAST(NULL AS STRING) AS k3_bot,
      CAST(NULL AS STRING) AS k9_top, CAST(NULL AS STRING) AS k9_t2b, CAST(NULL AS STRING) AS k9_bot),
    STRUCT(-99, CONCAT('Table ', CAST(q.table_num AS STRING)),
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-98, q.question_text,
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-97, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-96, 'Base: kids panels + meta', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-95, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-94, '',
      '4-6', '7-12',
      '4-6·Men', '4-6·Women', '7-12·Men', '7-12·Women',
      '7-9', '10-12',
      'Lat 7-12', 'Blk 7-12', 'Wht 7-12',
      'K3 TOP', 'K3 T2B', 'K3 BOT', 'K9 TOP', 'K9 T2B', 'K9 BOT'),
    STRUCT(-93, '',
      'K3', 'K9', 'K3', 'K3', 'K9', 'K9', 'K9', 'K9', 'K9', 'K9', 'K9',
      '', '', '', '', '', ''),
    STRUCT(-92, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ]) AS x
),

body AS (
  SELECT
    w.table_num,
    w.stub_sort AS sort_key,
    w.stub_label,
    w.c_46, w.c_712, w.c_46_men, w.c_46_women, w.c_712_men, w.c_712_women,
    w.c_79, w.c_1012, w.eth_lat_712, w.eth_blk_712, w.eth_wht_712,
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
  c_46 AS age_4_6,
  c_712 AS age_7_12,
  c_46_men AS men_4_6,
  c_46_women AS women_4_6,
  c_712_men AS men_7_12,
  c_712_women AS women_7_12,
  c_79 AS age_7_9,
  c_1012 AS age_10_12,
  eth_lat_712 AS latino_7_12,
  eth_blk_712 AS black_7_12,
  eth_wht_712 AS white_7_12,
  k3_top, k3_t2b, k3_bot,
  k9_top, k9_t2b, k9_bot
FROM (
  SELECT * FROM hdr
  UNION ALL
  SELECT * FROM body
)
ORDER BY table_num, sort_key;
