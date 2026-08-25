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
-- Only TWO of the nine routed questions actually surface here: POLORIENT
-- (338 vs 398) and ELEMENT2 (347 vs 398). The other seven -- PARENT2, LIKE,
-- DISLIKE, URG2, PRELIKE1, PRELIKE2 and the no-op RECONFIRM -- are open_end,
-- excluded from this mart by the filter below and tabulated in Phase 4. So the
-- base flag on fct_response carries most of its value forward to verbatim
-- coding, not to these banner tables. That is expected, not a gap: PARENT2's
-- 291 out-of-base personas matter when its verbatims are coded, and the flag is
-- already correct there.
--
-- WHERE is_primary_run on both, without exception: the replicated section 2.1
-- questions double-count 198 personas otherwise.
--
-- F10 -- the theatre item's base
-- The ACTIVITIES battery is one 6-point scale, but the theatre item screens out
-- "Never" (punch 6, measured: 2 personas at primary-run grain), so punch 6
-- leaves ITS base only -- 396, not 398 -- and it gains T3B (punches 1-3), the
-- read the banner plan annotates for it. TB/T2B are still emitted for it, since
-- it is a genuine ordinal question; the banner reads T3B and every row names
-- its own metric, so nothing is lost and nothing is implied.
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

-- v_response_metrics ALREADY carries metric_kind (it joins dim_question to gate
-- the box flags), so joining dim_question again here produced two columns of
-- that name and every later reference to it was ambiguous. Read it off the view.
WITH base AS (
  SELECT
    m.*,
    -- F10: punch 6 is a screen-out on the theatre item, so it is not in base
    NOT (m.meta = 'ACTIVITIES'
         AND m.question_text LIKE '%theater%'
         AND m.primary_code = 6) AS in_question_base
  FROM `${PROJECT_ID}.${DS_CUR}.v_response_metrics` AS m
  WHERE m.is_primary_run
    AND m.metric_kind != 'open_end'
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

      -- Every measure below is gated on metric_kind EXPLICITLY. Relying on the
      -- view's NULL box flags is not enough, and this is the trap: COUNTIF(NULL)
      -- is 0, not NULL, so SAFE_DIVIDE(0, n) is 0.0 -- a confident "0% top box"
      -- on all 9 pick-lists, all 15 ELEMENT1 items and both single-option
      -- formalities. That is exactly the wrong-number-instead-of-absent-number
      -- failure v_response_metrics was built to stop, reintroduced one layer up.
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_tb),  COUNT(*)), NULL) AS tb_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_t2b), COUNT(*)), NULL) AS t2b_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_bot), COUNT(*)), NULL) AS bot_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_b2b), COUNT(*)), NULL) AS b2b_pct,

      -- A mean needs a rank. ELEMENT1's three punches rotate (F9) and a
      -- multi-select's option_code is a category id, so averaging either is
      -- arithmetic on labels.
      IF(metric_kind = 'ordinal_scale',
         AVG(IF(primary_code < 90, primary_code, NULL)), NULL) AS mean_score,
      IF(metric_kind = 'numeric_rating', AVG(rating_value), NULL) AS mean_rating,

      -- F10: T3B belongs to the theatre item alone. Ungated it would attach a
      -- punches-1-3 read to all 54 ordinal questions, where it means nothing.
      IF(meta = 'ACTIVITIES' AND question_text LIKE '%theater%',
         SAFE_DIVIDE(COUNTIF(primary_code IN (1, 2, 3)), COUNT(*)), NULL) AS t3b_pct
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
  -- Each measure above is NULL wherever it does not apply, so this one line is
  -- what keeps a meaningless metric out of the table rather than in it at 0.
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
      -- The cut's base: the denominator for every option percentage below.
      --
      -- COUNT(*), not COUNT(DISTINCT archetype_id) -- BigQuery rejects DISTINCT
      -- in an analytic call. They are equal here because is_primary_run leaves
      -- exactly one row per (persona, question) and each persona matches a given
      -- (cut_name, cut_value) once, so a partition holds one row per persona.
      -- That invariant is not assumed silently: M-11 asserts POSTINT's TOTAL
      -- base is 398, which is this same count and would read 796 if it broke.
      COUNT(*) OVER (
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
