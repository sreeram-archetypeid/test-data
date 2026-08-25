-- mart_banner_read: the banner tables, long/tidy. Pivot at presentation time.
--
-- Grain: (base_kind, creative, question_key, cut_name, cut_value, metric_name,
--         option_code). One row per number that would appear in a banner cell.
--
-- THE MEASURE DEPENDS ON metric_kind. Applying box metrics everywhere is what
-- F9 and the earlier close-out were about:
--
--   ordinal_scale   n, tb_pct, t2b_pct, bot_pct, b2b_pct, mean_score
--   categorical     n, pct_of_base per option   (ELEMENT1 -- MEAN is undefined,
--                   its punches rotate, so it is not a rank)
--   multi_select    n, incidence_pct per option (from fct_response_option)
--   single_option   n only
--   numeric_rating  n, mean_rating
--   open_end        excluded -- tabulated in Phase 4
--
-- GROUPED BY question_key, NEVER meta alone. Two metas span multiple
-- metric_kind values: ACTIVITIES (numeric_rating + ordinal_scale) and
-- Screener 2 (open_end + single_option), 4,768 fact rows between them. A
-- meta-level aggregation silently mixes measurement channels.
--
-- base_kind
-- ---------
-- 'qre'        is_in_qre_base -- the routing the questionnaire defines, and the
--              only base comparable to the human W-Tabs study
-- 'unfiltered' every answer the synthetic panel produced
--
-- Both are emitted so nothing has to be recomputed to switch, and every row
-- declares which base produced it. 676 rows differ between them (F11).
--
-- WHERE is_primary_run on both, without exception: the replicated section 2.1
-- questions double-count 198 personas otherwise.
--
-- F10 -- the theatre item's base
-- The ACTIVITIES battery is one 6-point scale, but the theatre item screens out
-- "Never", so punch 6 leaves ITS base only and it reports T3B (punches 1-3)
-- rather than TB/T2B. Per the questionnaire's own screener and the banner
-- plan's annotation.
--
-- KNOWN GAP -- EXPOSURE ORDER
-- The banner plan defines 9 cuts on Banner 1; 8 are built here. Nothing in the
-- CSVs encodes exposure order. Cohort .1/.2 is the obvious candidate but
-- nothing confirms it, and a wrong guess produces a banner column that looks
-- right and means nothing. Emitted as an explicit NULL cut so its absence is
-- visible in the output rather than silently missing.
--
-- The 417 sentinel-only responses ("None of the above" as the sole selection)
-- are INCLUDED in n and EXCLUDED from box numerators. They are real answers.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_MART}.mart_banner_read`
CLUSTER BY base_kind, creative, meta AS

WITH base AS (
  SELECT
    m.*,
    q.metric_kind,
    -- F10: punch 6 is a screen-out on the theatre item, so it is not in base
    NOT (m.meta = 'ACTIVITIES'
         AND m.question_text LIKE '%theater%'
         AND m.primary_code = 6) AS in_question_base
  FROM `${PROJECT_ID}.${DS_CUR}.v_response_metrics` AS m
  JOIN `${PROJECT_ID}.${DS_CUR}.dim_question` AS q USING (question_key)
  WHERE m.is_primary_run
    AND q.metric_kind != 'open_end'
),
-- one row per (response, base_kind): 'unfiltered' keeps everything, 'qre'
-- keeps only what the questionnaire would have asked
scoped AS (
  SELECT b.* EXCEPT (in_question_base), k AS base_kind
  FROM base AS b
  CROSS JOIN UNNEST(['qre', 'unfiltered']) AS k
  WHERE b.in_question_base
    AND (k = 'unfiltered' OR b.is_in_qre_base)
),
-- expand each response across every banner cut it belongs to
cut AS (
  SELECT
    s.*,
    c.cut_name,
    c.cut_value
  FROM scoped AS s
  JOIN `${PROJECT_ID}.${DS_CUR}.dim_archetype` AS a USING (archetype_id)
  LEFT JOIN `${PROJECT_ID}.${DS_MART}.dim_archetype_cuts` AS x USING (archetype_id)
  CROSS JOIN UNNEST([
    STRUCT('TOTAL'         AS cut_name, 'Total'                                  AS cut_value),
    STRUCT('GENDER',        a.gender_clean),
    STRUCT('AGE',           a.age_band_banner),
    STRUCT('GENDER_AGE',    CONCAT(SUBSTR(a.gender_clean, 1, 1), ' ', a.age_band_banner)),
    STRUCT('RACE',          a.race_banner),
    STRUCT('INCOME',        a.income_band_banner),
    STRUCT('RELATIONSHIP',  a.marital_banner),
    STRUCT('PARENT',        IF(a.is_parent, 'Parents', 'Non-Parents')),
    STRUCT('GENRE_FAN_TB',  IF(x.cut_fan_martial_arts, 'GFAN Martial Arts TB', NULL)),
    STRUCT('GENRE_FAN_TB',  IF(x.cut_fan_anime,        'GFAN Anime TB',        NULL)),
    STRUCT('MEDIA_TB',      IF(x.cut_heavy_gamer,      'Plays games daily',    NULL)),
    STRUCT('MEDIA_TB',      IF(x.cut_heavy_cinema,     'Cinema daily',         NULL)),
    STRUCT('VG_APPEAL_TB',  IF(x.cut_knows_fatal_fury, 'Knows Fatal Fury',     NULL)),
    STRUCT('POSTINT_TB',    IF(x.cut_postint_tb,       'POSTINT TB',           NULL))
    -- EXPOSURE_ORDER is deliberately absent, not forgotten. Emitting it with a
    -- placeholder label would attach real percentages to a cut that does not
    -- exist, which misleads worse than its absence. See the header note.
  ]) AS c
  WHERE c.cut_value IS NOT NULL
),
-- aggregate measures: valid for ordinal and numeric questions
agg AS (
  SELECT
    base_kind, creative, meta, question_text, question_key, metric_kind,
    cut_name, cut_value,
    mm.metric_name,
    CAST(NULL AS INT64)  AS option_code,
    CAST(NULL AS STRING) AS option_label,
    n,
    mm.value
  FROM (
    SELECT
      base_kind, creative, meta, question_text, question_key, metric_kind,
      cut_name, cut_value,
      COUNT(*) AS n,
      SAFE_DIVIDE(COUNTIF(is_tb),  COUNT(*))  AS tb_pct,
      SAFE_DIVIDE(COUNTIF(is_t2b), COUNT(*))  AS t2b_pct,
      SAFE_DIVIDE(COUNTIF(is_bot), COUNT(*))  AS bot_pct,
      SAFE_DIVIDE(COUNTIF(is_b2b), COUNT(*))  AS b2b_pct,
      AVG(IF(primary_code < 90, primary_code, NULL)) AS mean_score,
      AVG(rating_value)                              AS mean_rating,
      -- F10: T3B, used only by the theatre item
      SAFE_DIVIDE(COUNTIF(primary_code IN (1, 2, 3)), COUNT(*)) AS t3b_pct
    FROM cut
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
  )
  CROSS JOIN UNNEST([
    STRUCT('N'            AS metric_name, CAST(n AS FLOAT64) AS value),
    STRUCT('TB_PCT',      tb_pct),
    STRUCT('T2B_PCT',     t2b_pct),
    STRUCT('BOT_PCT',     bot_pct),
    STRUCT('B2B_PCT',     b2b_pct),
    STRUCT('MEAN',        mean_score),
    STRUCT('MEAN_RATING', mean_rating),
    STRUCT('T3B_PCT',     t3b_pct)
  ]) AS mm
  -- box metrics are NULL off ordinal_scale by construction, so this drops the
  -- rows that would otherwise carry a meaningless measure
  WHERE mm.value IS NOT NULL
),
-- per-option measures: the correct grain for pick-lists and for ELEMENT1
opt AS (
  SELECT
    c.base_kind, c.creative, c.meta, c.question_text, c.question_key,
    c.metric_kind, c.cut_name, c.cut_value,
    IF(c.metric_kind = 'multi_select', 'INCIDENCE_PCT', 'PCT_OF_BASE') AS metric_name,
    o.option_code,
    o.option_label,
    COUNT(DISTINCT c.archetype_id) AS n,
    SAFE_DIVIDE(
      COUNT(DISTINCT c.archetype_id),
      MAX(c.cut_base_n)
    ) AS value
  FROM (
    SELECT
      cut.*,
      COUNT(DISTINCT archetype_id) OVER (
        PARTITION BY base_kind, creative, question_key, cut_name, cut_value
      ) AS cut_base_n
    FROM cut
  ) AS c,
  UNNEST(c.selected_options) AS o
  WHERE c.metric_kind IN ('multi_select', 'categorical')
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
)
SELECT * FROM agg
UNION ALL
SELECT * FROM opt;
