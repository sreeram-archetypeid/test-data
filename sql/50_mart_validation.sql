-- mart_validation: the synthetic banner against the human banner, cell by cell.
--
-- Grain: one row per (question_key, cut_name, cut_value, option_label,
--        wtab_layout).
--
-- wtab_layout is part of the grain because a cell can have TWO human sources:
-- ACTIVITIES 'play video games' x 'Every week' is printed both in that item's
-- own per_item table and in the 'Every week' summary table across all items.
-- 2,105 cells are duplicated this way, and all 2,105 agree to the printed
-- digit (worst gap 0.0pp) -- which makes this an independent consistency check
-- on THEIR file, not a defect in ours. Deduplicating would have thrown that
-- check away, so both rows are kept and the layout says where each came from.
-- A consumer wanting one row per cell should filter on a layout.
--
-- This is the warehouse twin of tools/build_comparison_csv.py. That script stays
-- the reproducible artifact -- it runs from repo files with no credentials, so
-- anyone can regenerate it byte-identically and it never goes stale. What it
-- cannot do is let someone else query the comparison or join it to a mart
-- without running Python. This table is that.
--
-- The join has three legs, and each is a place a naive version goes wrong:
--
--   1. QUESTION. Their table knows only a table_no, so ref_wtab_tables bridges
--      it to a meta and ref_wtab_crosswalk maps (meta, item) to our
--      question_key. Only target_class='question' rows join here: 'concept'
--      rows map to our `creative` rather than to an item, 'archetype' rows to a
--      persona attribute, and 'open_end' rows are Phase 4's problem.
--
--   2. BANNER COLUMN. Their (banner_group, banner_col) to our
--      (cut_name, cut_value), via the literal map below. It mirrors
--      tools/validate_local.PAIRS exactly and the runner asserts the row count
--      matches, so the two cannot drift silently.
--
--   3. ANSWER OPTION. Their metric_label to our option_label, normalised.
--      Their percentages are whole integers, so a gap under 1pp is inside
--      their own rounding.
--
-- EXCLUSIONS, all deliberate:
--   is_sigma   a column total, not an answer.
--   is_net     a roll-up of the indented rows beneath it. Joining a NET on an
--              option label matches nothing, and a generator that then writes
--              0% produces a confident wrong number -- exactly the defect
--              fixed in tools/build_wtabs_style_csv.py. Excluded at source.
--
-- SCOPE: base_kind='qre' and creative='(pooled)', because Banner 1 reports
-- across both concepts (Total = 800). Banner 2 splits them and needs the
-- per-creative rows instead.
--
-- comparability is carried through so a consumer cannot read a cell without it.
-- 'demographic' families reconcile within 1.7pp; 'behavioural' families diverge
-- 22-73pp because the panel was generated on-theme, so those columns hold a
-- different KIND of group on each side and compare directionally only.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_MART}.mart_validation`
CLUSTER BY comparability, meta AS

WITH colmap AS (
  -- Mirrors tools/validate_local.PAIRS. Asserted for count in
  -- tools/validate_banners.sh.
  SELECT * FROM UNNEST([
    STRUCT('GENDER' AS wtab_group, 'Men' AS wtab_col, 'GENDER' AS cut_name, 'Men' AS cut_value),
    STRUCT('GENDER' AS wtab_group, 'Women' AS wtab_col, 'GENDER' AS cut_name, 'Women' AS cut_value),
    STRUCT('QUADRANTS' AS wtab_group, 'Men <35' AS wtab_col, 'QUADRANTS' AS cut_name, 'Men <35' AS cut_value),
    STRUCT('QUADRANTS' AS wtab_group, 'Men 35+' AS wtab_col, 'QUADRANTS' AS cut_name, 'Men 35+' AS cut_value),
    STRUCT('QUADRANTS' AS wtab_group, 'Women <35' AS wtab_col, 'QUADRANTS' AS cut_name, 'Women <35' AS cut_value),
    STRUCT('QUADRANTS' AS wtab_group, 'Women 35+' AS wtab_col, 'QUADRANTS' AS cut_name, 'Women 35+' AS cut_value),
    STRUCT('AGE BREAKOUT' AS wtab_group, '13-24' AS wtab_col, 'AGE BREAKOUT' AS cut_name, '13-24' AS cut_value),
    STRUCT('AGE BREAKOUT' AS wtab_group, '25-34' AS wtab_col, 'AGE BREAKOUT' AS cut_name, '25-34' AS cut_value),
    STRUCT('AGE BREAKOUT' AS wtab_group, '35-44' AS wtab_col, 'AGE BREAKOUT' AS cut_name, '35-44' AS cut_value),
    STRUCT('AGE BREAKOUT' AS wtab_group, '45-64' AS wtab_col, 'AGE BREAKOUT' AS cut_name, '45-64' AS cut_value),
    STRUCT('MEN AGE DETAIL' AS wtab_group, 'Men 13-24' AS wtab_col, 'MEN AGE DETAIL' AS cut_name, 'Men 13-24' AS cut_value),
    STRUCT('MEN AGE DETAIL' AS wtab_group, 'Men 25-34' AS wtab_col, 'MEN AGE DETAIL' AS cut_name, 'Men 25-34' AS cut_value),
    STRUCT('MEN AGE DETAIL' AS wtab_group, 'Men 35-44' AS wtab_col, 'MEN AGE DETAIL' AS cut_name, 'Men 35-44' AS cut_value),
    STRUCT('MEN AGE DETAIL' AS wtab_group, 'Men 45-64' AS wtab_col, 'MEN AGE DETAIL' AS cut_name, 'Men 45-64' AS cut_value),
    STRUCT('ETHNICITY (QUOTA DEFINITIONS)' AS wtab_group, 'Caucasian/Asian/Other' AS wtab_col, 'ETHNICITY' AS cut_name, 'Caucasian/Asian/Other' AS cut_value),
    STRUCT('ETHNICITY (QUOTA DEFINITIONS)' AS wtab_group, 'Hispanic/Latino' AS wtab_col, 'ETHNICITY' AS cut_name, 'Hispanic/Latino' AS cut_value),
    STRUCT('ETHNICITY (QUOTA DEFINITIONS)' AS wtab_group, 'AA/Black' AS wtab_col, 'ETHNICITY' AS cut_name, 'AA/Black' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Know a lot' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Know a lot' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Know a little' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Know a little' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Heard of' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Heard of' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Never Heard of' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Never Heard of' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Total Know' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Total Know' AS cut_value),
    STRUCT('FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)' AS wtab_group, 'Non-Players' AS wtab_col, 'FF FAMILIARITY' AS cut_name, 'Non-Players' AS cut_value),
    STRUCT('REGION (ZIP)' AS wtab_group, 'Northeast' AS wtab_col, 'REGION' AS cut_name, 'Northeast' AS cut_value),
    STRUCT('REGION (ZIP)' AS wtab_group, 'Midwest' AS wtab_col, 'REGION' AS cut_name, 'Midwest' AS cut_value),
    STRUCT('REGION (ZIP)' AS wtab_group, 'South' AS wtab_col, 'REGION' AS cut_name, 'South' AS cut_value),
    STRUCT('REGION (ZIP)' AS wtab_group, 'West' AS wtab_col, 'REGION' AS cut_name, 'West' AS cut_value),
    STRUCT('GENRE FANS (P1 @ GFAN1)' AS wtab_group, 'Action' AS wtab_col, 'GENRE FANS' AS cut_name, 'Action' AS cut_value),
    STRUCT('GENRE FANS (P1 @ GFAN1)' AS wtab_group, 'Martial Arts' AS wtab_col, 'GENRE FANS' AS cut_name, 'Martial Arts' AS cut_value),
    STRUCT('GENRE FANS (P1 @ GFAN1)' AS wtab_group, 'Anime' AS wtab_col, 'GENRE FANS' AS cut_name, 'Anime' AS cut_value),
    STRUCT('GAMING' AS wtab_group, 'Daily' AS wtab_col, 'GAMING' AS cut_name, 'Daily' AS cut_value),
    STRUCT('GAMING' AS wtab_group, 'Weekly/Monthly' AS wtab_col, 'GAMING' AS cut_name, 'Weekly/Monthly' AS cut_value),
    STRUCT('POSTINT' AS wtab_group, 'Definitely' AS wtab_col, 'POSTINT' AS cut_name, 'Definitely' AS cut_value),
    STRUCT('POSTINT' AS wtab_group, 'Probably' AS wtab_col, 'POSTINT' AS cut_name, 'Probably' AS cut_value),
    STRUCT('POSTINT' AS wtab_group, 'Prob/Def Not' AS wtab_col, 'POSTINT' AS cut_name, 'Prob/Def Not' AS cut_value),
    STRUCT('MOVIEGOING (P1 @ ACTIVITIES)' AS wtab_group, 'Weekly/Monthly' AS wtab_col, 'MOVIEGOING' AS cut_name, 'Weekly/Monthly' AS cut_value),
    STRUCT('MOVIEGOING (P1 @ ACTIVITIES)' AS wtab_group, 'Every 2-6 Months' AS wtab_col, 'MOVIEGOING' AS cut_name, 'Every 2-6 Months' AS cut_value)
  ])
),
ours AS (
  SELECT
    m.question_key, m.meta, m.question_text, m.cut_name, m.cut_value,
    m.comparability, m.option_label, m.option_code,
    m.value AS ours_pct,
    m.n     AS ours_n
  FROM `${PROJECT_ID}.${DS_MART}.mart_banner_wtab` AS m
  WHERE m.base_kind = 'qre'
    AND m.creative  = '(pooled)'
    AND m.metric_name IN ('PCT_OF_BASE', 'INCIDENCE_PCT')
    AND m.option_label IS NOT NULL
),
theirs AS (
  SELECT
    x.question_key,
    t.banner,
    t.table_no,
    r.banner_group,
    r.banner_col,
    r.metric_label,
    t.layout        AS wtab_layout,
    r.pct           AS theirs_pct,
    r.freq          AS theirs_freq,
    r.banner_base_n AS theirs_base_n,
    r.src_pct
  FROM `${PROJECT_ID}.${DS_CUR}.ref_wtabs`         AS r
  JOIN `${PROJECT_ID}.${DS_CUR}.ref_wtab_tables`   AS t
    USING (banner, table_no)
  JOIN `${PROJECT_ID}.${DS_CUR}.ref_wtab_crosswalk` AS x
    ON  x.wtab_meta = t.meta
    AND x.target_class = 'question'
    -- A summary table's ROWS are the battery items; a per_item table's marker
    -- is the item and its rows are that item's options.
    AND COALESCE(x.wtab_item, '') = COALESCE(
          IF(t.layout = 'summary', r.row_label, t.marker), '')
  WHERE NOT r.is_sigma
    AND NOT r.is_net
    AND r.banner = 'Ban1'
    AND x.question_key IS NOT NULL
)
SELECT
  o.meta,
  o.question_text,
  o.question_key,
  th.table_no,
  th.wtab_layout,
  o.cut_name,
  o.cut_value,
  o.comparability,
  o.option_code,
  o.option_label,
  o.ours_n,
  o.ours_pct,
  th.theirs_freq,
  th.theirs_base_n,
  th.theirs_pct,
  ROUND((o.ours_pct - th.theirs_pct) * 100, 1) AS delta_pp,
  -- Their percentages are printed as whole integers, so anything inside 1pp is
  -- within their own rounding and should not be called a difference.
  CASE
    WHEN ABS(o.ours_pct - th.theirs_pct) * 100 <= 1  THEN 'within rounding'
    WHEN ABS(o.ours_pct - th.theirs_pct) * 100 <= 5  THEN 'close'
    WHEN ABS(o.ours_pct - th.theirs_pct) * 100 <= 15 THEN 'diverges'
    ELSE 'incomparable'
  END AS status
FROM ours AS o
JOIN colmap AS c
  ON c.cut_name = o.cut_name AND c.cut_value = o.cut_value
JOIN theirs AS th
  ON  th.question_key = o.question_key
  AND th.banner_group = c.wtab_group
  AND th.banner_col   = c.wtab_col
  -- On a SUMMARY table their metric_label is the marker verbatim --
  --     'Increases my interest' Summary Table
  -- quotes, suffix and all -- not the bare option label. Joining on it raw
  -- silently drops every summary table, which is 56 of their 152 and was
  -- costing 37 of 75 questions. Strip the suffix and the surrounding quotes
  -- (straight and curly), and normalise the apostrophe, which differs between
  -- their cp1252 source and our UTF-8.
  -- RE2 has no \uXXXX escape, so the curly quotes are written literally.
  AND REGEXP_REPLACE(
        LOWER(TRIM(REGEXP_REPLACE(
          REGEXP_REPLACE(th.metric_label, r'(?i)\s*Summary Table\s*$', ''),
          r"^['‘’]+|['‘’]+$", ''))),
        r'[‘’]', "'")
    = REGEXP_REPLACE(LOWER(TRIM(o.option_label)), r'[‘’]', "'");
