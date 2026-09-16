-- Persona / meta inventory tables (W-Tabs Tables 1–N before questionnaire).
-- Rows = meta attribute levels; columns = panels 4-6 / 7-12 / 12-64 + gender.

CREATE OR REPLACE TABLE `archetypeid-staging.svy.render_abr_persona_meta` AS

WITH people AS (
  SELECT * FROM `archetypeid-staging.svy.abr_respondent_meta`
  WHERE study_id = 'drop-002'
),

panel_base AS (
  SELECT panel_label, COUNT(*) AS n_base
  FROM people
  GROUP BY 1
),

attrs AS (
  SELECT panel_label, 'AGE' AS attr, CAST(age_num AS STRING) AS level FROM people WHERE age_num IS NOT NULL
  UNION ALL
  SELECT panel_label, 'AGE_BAND', age_band_cut FROM people WHERE age_band_cut IS NOT NULL
  UNION ALL
  SELECT panel_label, 'GENDER', gender_banner FROM people WHERE gender_banner IS NOT NULL
  UNION ALL
  SELECT panel_label, 'ETHNICITY', ethnicity FROM people WHERE ethnicity IS NOT NULL
  UNION ALL
  SELECT panel_label, 'LOCATION', location_type FROM people WHERE location_type IS NOT NULL
  UNION ALL
  SELECT panel_label, 'ADOPTION', adoption FROM people WHERE adoption IS NOT NULL
  UNION ALL
  SELECT panel_label, 'CHILDREN', children_status FROM people
  WHERE panel_label = '12-64' AND children_status IS NOT NULL
),

counts AS (
  SELECT
    attr,
    level,
    panel_label,
    COUNT(*) AS n
  FROM attrs
  GROUP BY 1, 2, 3
),

with_pct AS (
  SELECT
    c.attr,
    c.level,
    c.panel_label,
    c.n,
    b.n_base,
    SAFE_DIVIDE(c.n, b.n_base) AS pct,
    CONCAT(FORMAT('%.1f', SAFE_DIVIDE(c.n, b.n_base) * 100), '%') AS pct_1dp
  FROM counts AS c
  INNER JOIN panel_base AS b USING (panel_label)
),

wide AS (
  SELECT
    attr,
    level,
    IFNULL(MAX(IF(panel_label = '4-6', CAST(n AS STRING), NULL)), '0') AS n_4_6,
    IFNULL(MAX(IF(panel_label = '7-12', CAST(n AS STRING), NULL)), '0') AS n_7_12,
    IFNULL(MAX(IF(panel_label = '12-64', CAST(n AS STRING), NULL)), '0') AS n_12_64,
    IFNULL(MAX(IF(panel_label = '4-6', pct_1dp, NULL)), '0.0%') AS pct_4_6,
    IFNULL(MAX(IF(panel_label = '7-12', pct_1dp, NULL)), '0.0%') AS pct_7_12,
    IFNULL(MAX(IF(panel_label = '12-64', pct_1dp, NULL)), '0.0%') AS pct_12_64
  FROM with_pct
  GROUP BY attr, level
),

attr_order AS (
  SELECT * FROM UNNEST([
    STRUCT('AGE' AS attr, 1 AS attr_sort, 'AGE. Persona age' AS title),
    STRUCT('AGE_BAND', 2, 'AGE BAND. Persona age band'),
    STRUCT('GENDER', 3, 'GENDER. Persona gender'),
    STRUCT('ETHNICITY', 4, 'ETHNICITY. Persona race / ethnicity'),
    STRUCT('LOCATION', 5, 'LOCATION. Location type'),
    STRUCT('ADOPTION', 6, 'ADOPTION. Adoption category'),
    STRUCT('CHILDREN', 7, 'CHILDREN. Children status (HTR only)')
  ])
),

hdr AS (
  SELECT
    o.attr_sort AS table_num,
    h.sort_key,
    h.stub_label,
    h.n_4_6, h.n_7_12, h.n_12_64, h.pct_4_6, h.pct_7_12, h.pct_12_64
  FROM attr_order AS o
  CROSS JOIN UNNEST([
    STRUCT(-100 AS sort_key, '#page' AS stub_label,
      CAST(NULL AS STRING) AS n_4_6, CAST(NULL AS STRING) AS n_7_12, CAST(NULL AS STRING) AS n_12_64,
      CAST(NULL AS STRING) AS pct_4_6, CAST(NULL AS STRING) AS pct_7_12, CAST(NULL AS STRING) AS pct_12_64),
    STRUCT(-99, CONCAT('Table ', CAST(o.attr_sort AS STRING)), NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-98, o.title, NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-97, '', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-96, 'Base: panel respondents', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-95, '', NULL, NULL, NULL, NULL, NULL, NULL),
    STRUCT(-94, '', '4-6 n', '7-12 n', '12-64 n', '4-6 %', '7-12 %', '12-64 %'),
    STRUCT(-93, '', 'K3', 'K9', 'HTR', 'K3', 'K9', 'HTR'),
    STRUCT(-92, '', NULL, NULL, NULL, NULL, NULL, NULL)
  ]) AS h
),

body AS (
  SELECT
    o.attr_sort AS table_num,
    100 + ROW_NUMBER() OVER (PARTITION BY w.attr ORDER BY w.level) AS sort_key,
    w.level AS stub_label,
    w.n_4_6, w.n_7_12, w.n_12_64, w.pct_4_6, w.pct_7_12, w.pct_12_64
  FROM wide AS w
  INNER JOIN attr_order AS o USING (attr)
)

SELECT stub_label, n_4_6, n_7_12, n_12_64, pct_4_6, pct_7_12, pct_12_64
FROM (
  SELECT * FROM hdr
  UNION ALL
  SELECT * FROM body
)
ORDER BY table_num, sort_key;
