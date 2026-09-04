-- mart_banner_wtab: the banner, in the human W-Tabs' shape.
--
-- Grain: (base_kind, creative, question_key, cut_name, cut_value, metric_name,
--         option_code). One row per number that would appear in a banner cell.
--
-- Companion to mart_banner_read (sql/41), not a replacement. That mart answers
-- the banner PLAN's columns; this one answers the human study's, so the two can
-- be compared cell for cell in sql/50. Same metric model, same base rules, same
-- grain — three deliberate differences and nothing else:
--
--   1. CUTS come from dim_cuts_wtab (sql/42), which is long, so this is a join
--      rather than a CROSS JOIN UNNEST of hardcoded STRUCTs. A new cut family
--      needs no change to this file.
--
--   2. CREATIVE gains a '(pooled)' value. W-Tabs Banner 1 reports across both
--      concepts (Total = 800) while Banner 2 splits them (400 each). Our mart is
--      grained by creative and cut_name='TOTAL' means "within one creative", so
--      there was no way to express a study total at all — M-21 exists precisely
--      because someone reached for MAX() to fake one. Emitting the pooled scope
--      explicitly is honest; making readers SUM two rows is not.
--
--      Never pool ELEMENT2. Its QRE gate excludes 29 Goyer personas but only 22
--      Sheridan (F14), so a pooled ELEMENT2 figure averages two different bases
--      and understates Goyer. Enforced in scoped_cr below, and re-asserted as a
--      gate in tools/build_wtab_banner.sh.
--
--   3a. AGE and INCOME gain BANDED option rows, and ZIPCODE loses its
--      meaningless mean. See the `banded` CTE.
--
--   3. PER-OPTION rows now cover ordinal_scale as well as multi_select and
--      categorical. This is the change that makes the table able to reproduce a
--      W-Tabs page at all, and it is worth being precise about why.
--
--      mart_banner_read describes POSTINT as TB_PCT 0.055 / T2B_PCT 0.865 /
--      MEAN 2.085 / N 200. Those are summaries. A W-Tabs page needs the
--      distribution — Definitely 6%, Probably 83%, Probably not 10%, Definitely
--      not 1%, SIGMA 100% — and the second cannot be derived from the first:
--      knowing the top box and the top-2 box says nothing about how the
--      remainder splits. 54 of the 81 questions in the mart are ordinal_scale,
--      so without this the bulk of the study cannot be tabulated in their shape.
--
--      Unnesting selected_options is correct for a single-punch question: each
--      persona has exactly one selected option, so the rows sum to the base and
--      the percentages to 100%. Sentinels ('99. None of the above') get their
--      own row, which matches the W-Tabs treating them as a real answer that
--      counts in the base and never in a box numerator (D9).
--
-- comparability
-- -------------
-- Carried through from dim_cuts_wtab so a consumer cannot read a cell without
-- it. 'demographic' families reconcile to the human study within 1.7pp;
-- 'behavioural' families diverge by 22-73pp because the panel was generated
-- on-theme, so those columns hold a different KIND of group on each side and
-- compare directionally only. Measured in tools/validate_local.py.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_MART}.mart_banner_wtab`
CLUSTER BY base_kind, creative, meta AS

-- Copied verbatim from sql/41. Deliberately not reworded: if a base rule ever
-- changes, the two files should differ by exactly that change and nothing else.
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
scoped AS (
  SELECT b.* EXCEPT (in_question_base), k AS base_kind
  FROM base AS b
  CROSS JOIN UNNEST(['qre', 'unfiltered']) AS k
  WHERE b.in_question_base
    AND (k = 'unfiltered' OR b.is_in_qre_base)
),
-- Each response appears under its own creative AND under '(pooled)'.
-- Banner 1 reads the pooled rows; Banner 2 reads the per-creative rows.
scoped_cr AS (
  SELECT s.* EXCEPT (creative), cr AS creative
  FROM scoped AS s
  CROSS JOIN UNNEST([s.creative, '(pooled)']) AS cr
  -- ELEMENT2 is never pooled under the QRE base. Measured: its gate leaves
  -- Goyer at 171 of 200 (14.5% excluded) and Sheridan at 176 of 198 (11.1%),
  -- so a pooled figure averages two differently-gated bases and understates
  -- Goyer. The header has said "never pool ELEMENT2" since this file was
  -- written, but nothing enforced it and the mart carried 484 such rows.
  --
  -- Excluded here rather than asserted in the runner: a row that must never be
  -- read is a trap whether or not a gate shouts about it afterwards.
  --
  -- The unfiltered scope is deliberately NOT excluded. No gate is applied
  -- there, so 398 = 200 + 198 and pooling is exactly what it claims to be.
  WHERE NOT (cr = '(pooled)' AND s.base_kind = 'qre' AND s.meta = 'ELEMENT2')
),
-- Expand each response across every banner column its persona belongs to.
-- dim_cuts_wtab is long, so a persona in 9 columns produces 9 rows here.
cut AS (
  SELECT
    s.*,
    w.cut_name,
    w.cut_value,
    w.comparability
  FROM scoped_cr AS s
  JOIN `${PROJECT_ID}.${DS_MART}.dim_cuts_wtab` AS w USING (archetype_id)
),
-- aggregate measures: valid for ordinal and numeric questions
agg AS (
  SELECT
    base_kind, creative, meta, question_text, question_key, metric_kind,
    cut_name, cut_value, comparability,
    mm.metric_name,
    CAST(NULL AS INT64)  AS option_code,
    CAST(NULL AS STRING) AS option_label,
    n,
    mm.value
  FROM (
    SELECT
      base_kind, creative, meta, question_text, question_key, metric_kind,
      cut_name, cut_value, comparability,
      COUNT(*) AS n,

      -- Gated on metric_kind EXPLICITLY, as in sql/41. COUNTIF(NULL) is 0, not
      -- NULL, so an ungated box metric yields a confident "0% top box" on every
      -- pick-list and ELEMENT1 item — a wrong number where there should be no
      -- number at all.
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_tb),  COUNT(*)), NULL) AS tb_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_t2b), COUNT(*)), NULL) AS t2b_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_bot), COUNT(*)), NULL) AS bot_pct,
      IF(metric_kind = 'ordinal_scale', SAFE_DIVIDE(COUNTIF(is_b2b), COUNT(*)), NULL) AS b2b_pct,
      IF(metric_kind = 'ordinal_scale',
         AVG(IF(primary_code < 90, primary_code, NULL)), NULL) AS mean_score,
      -- ZIPCODE is q_type 2, so it classifies as numeric_rating and an
      -- ungated AVG produces a MEAN ZIP CODE -- a confident number with no
      -- meaning at all, sitting in the mart next to real ones. AGE and INCOME
      -- are also numeric_rating and their means ARE meaningful, so this is
      -- excluded by name rather than by kind.
      IF(metric_kind = 'numeric_rating' AND meta != 'ZIPCODE',
         AVG(rating_value), NULL) AS mean_rating,
      IF(meta = 'ACTIVITIES' AND question_text LIKE '%theater%',
         SAFE_DIVIDE(COUNTIF(primary_code IN (1, 2, 3)), COUNT(*)), NULL) AS t3b_pct
    FROM cut
    GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
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
  WHERE mm.value IS NOT NULL
),
-- per-option measures. ordinal_scale is included here and NOT in sql/41 --
-- see note 3 in the header. This is what a W-Tabs table body is made of.
opt AS (
  SELECT
    c.base_kind, c.creative, c.meta, c.question_text, c.question_key,
    c.metric_kind, c.cut_name, c.cut_value, c.comparability,
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
      -- COUNT(*), not COUNT(DISTINCT archetype_id) -- BigQuery rejects DISTINCT
      -- in an analytic call. Equal here because is_primary_run leaves one row
      -- per (persona, question) and a persona matches a given (cut_name,
      -- cut_value) once, so a partition holds one row per persona.
      COUNT(*) OVER (
        PARTITION BY base_kind, creative, question_key, cut_name, cut_value
      ) AS cut_base_n
    FROM cut
  ) AS c,
  UNNEST(c.selected_options) AS o
  WHERE c.metric_kind IN ('multi_select', 'categorical', 'ordinal_scale')
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
),
-- Banded option rows for the two numeric questions that ARE tabulated.
--
-- AGE and INCOME arrive as q_type 2, so they classify as numeric_rating and the
-- agg block above gives them a mean and nothing else. A banner needs a
-- distribution, so each is cut into the human study's own bands (W-Tabs
-- Table 1 and Table 76) and emitted as PCT_OF_BASE rows, which is what makes
-- those two pages reproducible at all.
--
-- The bands are the HUMAN study's labels verbatim, so a row joins to theirs on
-- the label. They are a presentation choice about how to compare, not a
-- property of our data, which is why they live in the mart and not in
-- dim_question_option.
--
-- ZIPCODE is deliberately absent. Its rows in the human banner are the four
-- Census regions, and region is carried as a CUT (from the stated location, not
-- from the corrupt zip -- see sql/42), never as an answer distribution.
--
-- option_code is a band ordinal, not a scale point. Safe here because
-- metric_kind stays numeric_rating, so no box metric or MEAN is ever computed
-- over it.
banded AS (
  SELECT
    base_kind, creative, meta, question_text, question_key, metric_kind,
    cut_name, cut_value, comparability,
    'PCT_OF_BASE' AS metric_name,
    band_code     AS option_code,
    band_label    AS option_label,
    COUNT(*)      AS n,
    SAFE_DIVIDE(COUNT(*), MAX(cut_base_n)) AS value
  FROM (
    SELECT
      c.*,
      COUNT(*) OVER (
        PARTITION BY base_kind, creative, question_key, cut_name, cut_value
      ) AS cut_base_n,
      CASE
        WHEN c.meta = 'AGE' THEN CASE
          WHEN c.rating_value BETWEEN 13 AND 17 THEN 1
          WHEN c.rating_value BETWEEN 18 AND 24 THEN 2
          WHEN c.rating_value BETWEEN 25 AND 29 THEN 3
          WHEN c.rating_value BETWEEN 30 AND 34 THEN 4
          WHEN c.rating_value BETWEEN 35 AND 39 THEN 5
          WHEN c.rating_value BETWEEN 40 AND 44 THEN 6
          WHEN c.rating_value BETWEEN 45 AND 54 THEN 7
          WHEN c.rating_value BETWEEN 55 AND 64 THEN 8
        END
        WHEN c.meta = 'INCOME' THEN CASE
          WHEN c.rating_value <  20000 THEN 1
          WHEN c.rating_value <  40000 THEN 2
          WHEN c.rating_value <  70000 THEN 3
          WHEN c.rating_value < 100000 THEN 4
          ELSE 5
        END
      END AS band_code,
      CASE
        WHEN c.meta = 'AGE' THEN CASE
          WHEN c.rating_value BETWEEN 13 AND 17 THEN '13-17'
          WHEN c.rating_value BETWEEN 18 AND 24 THEN '18-24'
          WHEN c.rating_value BETWEEN 25 AND 29 THEN '25-29'
          WHEN c.rating_value BETWEEN 30 AND 34 THEN '30-34'
          WHEN c.rating_value BETWEEN 35 AND 39 THEN '35-39'
          WHEN c.rating_value BETWEEN 40 AND 44 THEN '40-44'
          WHEN c.rating_value BETWEEN 45 AND 54 THEN '45-54'
          WHEN c.rating_value BETWEEN 55 AND 64 THEN '55-64'
        END
        WHEN c.meta = 'INCOME' THEN CASE
          WHEN c.rating_value <  20000 THEN 'Under $20,000'
          WHEN c.rating_value <  40000 THEN '$20,000-$39,999'
          WHEN c.rating_value <  70000 THEN '$40,000-$69,999'
          WHEN c.rating_value < 100000 THEN '$70,000-$99,999'
          ELSE '$100,000 or more'
        END
      END AS band_label
    FROM cut AS c
    WHERE c.meta IN ('AGE', 'INCOME') AND c.rating_value IS NOT NULL
  )
  WHERE band_code IS NOT NULL
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
)
SELECT * FROM agg
UNION ALL
SELECT * FROM opt
UNION ALL
SELECT * FROM banded;
