-- HTR W-Tabs questionnaire book with meta banners.
-- Columns: HTR | Men/Women | <35/35+ | Ethnicity | Location | Adoption | Children | Boxes
-- Prereq: 01 boxes, 04 meta, 05 mart_abr_banner_meta

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_abr_htr_wtabs` AS

WITH questions AS (
  SELECT
    question_code,
    question_text,
    DENSE_RANK() OVER (
      ORDER BY SAFE_CAST(REGEXP_EXTRACT(question_code, r'(\d+)') AS INT64), question_text
    ) AS table_num
  FROM `archetypeid-staging.svy.mart_abr_banner_meta`
  WHERE study_id = 'drop-002'
    AND sample_arm = 'HTR'
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
    m.cell_1dp
  FROM `archetypeid-staging.svy.mart_abr_banner_meta` AS m
  INNER JOIN questions AS q
    ON m.question_code = q.question_code
   AND IFNULL(m.question_text, '') = IFNULL(q.question_text, '')
  WHERE m.study_id = 'drop-002'
    AND m.sample_arm = 'HTR'
    AND (
      (m.banner_group = 'PANEL' AND m.banner_cut = '12-64')
      OR (m.banner_group = 'GENDER' AND m.banner_cut IN ('Men', 'Women'))
      OR (m.banner_group = 'AGE_BAND' AND m.banner_cut IN ('HTR <35', 'HTR 35+'))
      OR (m.banner_group = 'ETHNICITY' AND m.banner_cut IN (
            'Latino / Hispanic', 'Black / African American',
            'White / Caucasian', 'Asian or Pacific Islander', 'Two or more races'))
      OR (m.banner_group = 'LOCATION' AND m.banner_cut IN (
            'Suburban', 'Urban', 'Rural', 'Exurban'))
      OR (m.banner_group = 'ADOPTION')
      OR (m.banner_group = 'CHILDREN')
      OR (m.banner_group = 'QUADRANTS' AND m.banner_cut IN (
            'Men · HTR <35', 'Men · HTR 35+', 'Women · HTR <35', 'Women · HTR 35+'))
    )
),

wide AS (
  SELECT
    table_num,
    ANY_VALUE(question_text) AS question_text,
    stub_sort,
    stub_label,
    IFNULL(MAX(IF(banner_group = 'PANEL' AND banner_cut = '12-64', cell_1dp, NULL)), '0.0%') AS htr,
    IFNULL(MAX(IF(banner_cut = 'Men', cell_1dp, NULL)), '0.0%') AS men,
    IFNULL(MAX(IF(banner_cut = 'Women', cell_1dp, NULL)), '0.0%') AS women,
    IFNULL(MAX(IF(banner_cut = 'HTR <35', cell_1dp, NULL)), '0.0%') AS age_lt35,
    IFNULL(MAX(IF(banner_cut = 'HTR 35+', cell_1dp, NULL)), '0.0%') AS age_ge35,
    IFNULL(MAX(IF(banner_cut = 'Men · HTR <35', cell_1dp, NULL)), '0.0%') AS men_lt35,
    IFNULL(MAX(IF(banner_cut = 'Men · HTR 35+', cell_1dp, NULL)), '0.0%') AS men_ge35,
    IFNULL(MAX(IF(banner_cut = 'Women · HTR <35', cell_1dp, NULL)), '0.0%') AS women_lt35,
    IFNULL(MAX(IF(banner_cut = 'Women · HTR 35+', cell_1dp, NULL)), '0.0%') AS women_ge35,
    IFNULL(MAX(IF(banner_cut = 'Latino / Hispanic', cell_1dp, NULL)), '0.0%') AS eth_lat,
    IFNULL(MAX(IF(banner_cut = 'Black / African American', cell_1dp, NULL)), '0.0%') AS eth_blk,
    IFNULL(MAX(IF(banner_cut = 'White / Caucasian', cell_1dp, NULL)), '0.0%') AS eth_wht,
    IFNULL(MAX(IF(banner_cut = 'Asian or Pacific Islander', cell_1dp, NULL)), '0.0%') AS eth_asn,
    IFNULL(MAX(IF(banner_cut = 'Suburban', cell_1dp, NULL)), '0.0%') AS loc_sub,
    IFNULL(MAX(IF(banner_cut = 'Urban', cell_1dp, NULL)), '0.0%') AS loc_urb,
    IFNULL(MAX(IF(banner_cut = 'Rural', cell_1dp, NULL)), '0.0%') AS loc_rur,
    IFNULL(MAX(IF(banner_group = 'ADOPTION' AND banner_cut = 'Early Adopter', cell_1dp, NULL)), '0.0%') AS adopt_early,
    IFNULL(MAX(IF(banner_group = 'ADOPTION' AND banner_cut = 'Early Majority', cell_1dp, NULL)), '0.0%') AS adopt_emaj,
    IFNULL(MAX(IF(banner_group = 'ADOPTION' AND banner_cut = 'Late Majority', cell_1dp, NULL)), '0.0%') AS adopt_lmaj,
    IFNULL(MAX(IF(banner_group = 'CHILDREN' AND banner_cut = 'young_children_at_home', cell_1dp, NULL)), '0.0%') AS kids_young,
    IFNULL(MAX(IF(banner_group = 'CHILDREN' AND banner_cut = 'no_children', cell_1dp, NULL)), '0.0%') AS kids_none
  FROM src
  GROUP BY table_num, stub_sort, stub_label
),

boxes AS (
  SELECT q.table_num, b.box_kind, b.pct_1dp
  FROM `archetypeid-staging.svy.mart_abr_boxes` AS b
  INNER JOIN questions AS q
    ON b.question_code = q.question_code
   AND IFNULL(b.question_text, '') = IFNULL(q.question_text, '')
  WHERE b.cut_id = 'arm' AND b.cut_value = 'HTR'
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

hdr AS (
  SELECT q.table_num, x.*
  FROM questions AS q
  CROSS JOIN UNNEST([
    STRUCT(-100 AS sort_key, '#page' AS stub_label,
      CAST(NULL AS STRING) AS htr, CAST(NULL AS STRING) AS men, CAST(NULL AS STRING) AS women,
      CAST(NULL AS STRING) AS age_lt35, CAST(NULL AS STRING) AS age_ge35,
      CAST(NULL AS STRING) AS men_lt35, CAST(NULL AS STRING) AS men_ge35,
      CAST(NULL AS STRING) AS women_lt35, CAST(NULL AS STRING) AS women_ge35,
      CAST(NULL AS STRING) AS eth_lat, CAST(NULL AS STRING) AS eth_blk,
      CAST(NULL AS STRING) AS eth_wht, CAST(NULL AS STRING) AS eth_asn,
      CAST(NULL AS STRING) AS loc_sub, CAST(NULL AS STRING) AS loc_urb, CAST(NULL AS STRING) AS loc_rur,
      CAST(NULL AS STRING) AS adopt_early, CAST(NULL AS STRING) AS adopt_emaj, CAST(NULL AS STRING) AS adopt_lmaj,
      CAST(NULL AS STRING) AS kids_young, CAST(NULL AS STRING) AS kids_none,
      CAST(NULL AS STRING) AS top_box, CAST(NULL AS STRING) AS t2b, CAST(NULL AS STRING) AS bottom_box),
    STRUCT(-99, CONCAT('Table ', CAST(q.table_num AS STRING)),
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-98, q.question_text,
      NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-97, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-96, 'Base: HTR (12-64) + meta', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-95, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-94, '',
      'HTR', 'Men', 'Women', '<35', '35+',
      'Men<35', 'Men35+', 'Women<35', 'Women35+',
      'Latino', 'Black', 'White', 'Asian',
      'Suburban', 'Urban', 'Rural',
      'EarlyAdpt', 'EarlyMaj', 'LateMaj',
      'YoungKids', 'NoKids',
      'TOP', 'T2B', 'BOT'),
    STRUCT(-93, '', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
  ]) AS x
),

body AS (
  SELECT
    w.table_num,
    w.stub_sort AS sort_key,
    w.stub_label,
    w.htr, w.men, w.women, w.age_lt35, w.age_ge35,
    w.men_lt35, w.men_ge35, w.women_lt35, w.women_ge35,
    w.eth_lat, w.eth_blk, w.eth_wht, w.eth_asn,
    w.loc_sub, w.loc_urb, w.loc_rur,
    w.adopt_early, w.adopt_emaj, w.adopt_lmaj,
    w.kids_young, w.kids_none,
    IF(w.stub_label = 'Total', b.top_box, CAST(NULL AS STRING)) AS top_box,
    IF(w.stub_label = 'Total', b.t2b, CAST(NULL AS STRING)) AS t2b,
    IF(w.stub_label = 'Total', b.bottom_box, CAST(NULL AS STRING)) AS bottom_box
  FROM wide AS w
  LEFT JOIN box_wide AS b USING (table_num)
)

SELECT
  stub_label,
  htr, men, women, age_lt35, age_ge35,
  men_lt35, men_ge35, women_lt35, women_ge35,
  eth_lat, eth_blk, eth_wht, eth_asn,
  loc_sub, loc_urb, loc_rur,
  adopt_early, adopt_emaj, adopt_lmaj,
  kids_young, kids_none,
  top_box, t2b, bottom_box
FROM (
  SELECT * FROM hdr
  UNION ALL
  SELECT * FROM body
)
ORDER BY table_num, sort_key;
