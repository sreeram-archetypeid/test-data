-- dim_cuts_wtab: persona-to-banner-column membership, in the human W-Tabs'
-- banner shape rather than the banner plan's.
--
-- Why a second cut table. dim_archetype_cuts (sql/40) implements the banner
-- PLAN's columns: GENDER / AGE / RACE / INCOME / RELATIONSHIP / PARENT plus four
-- top-box families. The W-Tabs banner is a different set — QUADRANTS, AGE
-- BREAKOUT, MEN AGE DETAIL, FATAL FURY FAMILIARITY, FATAL FURY FANSHIP, GENRE
-- FANS, ETHNICITY on quota definitions, GAMING, MOVIEGOING and POSTINT — and the
-- two overlap only on gender. Neither is a superset, so this sits alongside
-- sql/40 rather than replacing it.
--
-- Grain: (archetype_id, cut_name, cut_value). LONG, not wide.
--
-- sql/40 is wide, one BOOL column per flag, because its cuts are independent
-- top-box tests. These are not: a persona belongs to GENDER *and* QUADRANTS
-- *and* AGE BREAKOUT simultaneously, and most families partition the panel
-- rather than flagging a minority. Long form is what mart_banner_wtab needs to
-- cross-join, and it lets a family be added without a schema change.
--
-- Expected 398 personas; ~4,500 membership rows.
--
-- comparability
-- -------------
-- Every row carries whether its family can be compared to the human study at
-- all. This is measured, not assumed — tools/validate_local.py reconciled all
-- 13 families against the W-Tabs' own bases:
--
--   demographic   all 17 columns within 1.7pp of the human study. GENDER Men
--                 59.8% vs 60.0%, AGE BREAKOUT 13-24 26.1% vs 25.0%, ETHNICITY
--                 Hispanic/Latino 18.3% vs 20.0%. Our 398 share the human
--                 quota frame, so these cells are comparable as levels.
--
--   behavioural   diverge by 22-73pp. GENRE FANS Martial Arts is 92.5% of our
--                 panel against 19.5% of theirs; FF FAMILIARITY Total Know
--                 77.1% against 35.2%; only 10 of 398 personas have never heard
--                 of Fatal Fury against 38% of humans. The scales are verbatim
--                 identical on both sides, so this is a property of the panel,
--                 not a mapping artefact: the personas were generated on-theme.
--
--                 A behavioural column therefore holds a different KIND of group
--                 on each side — ours is effectively the whole panel, theirs a
--                 niche — so comparing the two as levels compares different
--                 populations. sql/50 reports these directionally and never as a
--                 delta to be fixed.
--
-- Membership is NOT exhaustive within every family. A persona missing a
-- question has no row for that family rather than a NULL bucket, so a family's
-- rows can sum to fewer than 398. That is deliberate: an absent answer is not a
-- category. mart_banner_wtab reads the base per (family, value), never 398.
--
-- Reads v_response_metrics WHERE is_primary_run throughout. Without it the
-- replicated section 2.1 double-counts 198 personas, and GFAN1, ACTIVITIES and
-- VGFRAN1 all live in that section.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_MART}.dim_cuts_wtab`
CLUSTER BY cut_name, cut_value AS

WITH
-- One row per persona per response-derived answer we need. Filtering on
-- question_text as well as meta is required: GFAN1 and VGFRAN1 are batteries of
-- 8 and 11 items, so meta alone collapses every genre or franchise into one.
r AS (
  SELECT
    archetype_id,
    MAX(IF(meta = 'VGFRAN1'    AND question_text LIKE '%Fatal Fury%',    primary_code, NULL)) AS ff_familiarity,
    MAX(IF(meta = 'VGFRAN2'    AND question_text LIKE '%Fatal Fury%',    primary_code, NULL)) AS ff_fanship,
    MAX(IF(meta = 'GFAN1'      AND question_text LIKE '%Action%',        primary_code, NULL)) AS gfan_action,
    MAX(IF(meta = 'GFAN1'      AND question_text LIKE '%Martial Arts%',  primary_code, NULL)) AS gfan_martial,
    MAX(IF(meta = 'GFAN1'      AND question_text LIKE '%Anim%',          primary_code, NULL)) AS gfan_anime,
    MAX(IF(meta = 'ACTIVITIES' AND question_text LIKE '%video games%',   primary_code, NULL)) AS act_games,
    MAX(IF(meta = 'ACTIVITIES' AND question_text LIKE '%theater%',       primary_code, NULL)) AS act_theatre,
    MAX(IF(meta = 'POSTINT',                                            primary_code, NULL)) AS postint
  FROM `${PROJECT_ID}.${DS_CUR}.v_response_metrics`
  WHERE is_primary_run
  GROUP BY archetype_id
),

a AS (
  SELECT
    d.archetype_id,
    d.creative,
    IF(d.gender_clean = 'Male', 'Men', 'Women')                  AS gender_w,
    -- AGE BREAKOUT merges our top two bands. The W-Tabs run 13-24 / 25-34 /
    -- 35-44 / 45-64, so 45-54 and 55-64 collapse into 45-64. age_band_banner
    -- stays untouched for the banner-plan mart.
    CASE d.age_band_banner
      WHEN '13-17' THEN '13-24' WHEN '18-24' THEN '13-24'
      WHEN '25-34' THEN '25-34' WHEN '35-44' THEN '35-44'
      WHEN '45-54' THEN '45-64' WHEN '55-64' THEN '45-64'
    END                                                          AS age_w,
    -- Under-35 for QUADRANTS. Derived from the band, not from exact age: the
    -- 25-34 / 35-44 boundary is exactly 35, so no band straddles the split.
    d.age_band_banner IN ('13-17', '18-24', '25-34')             AS under35,
    -- ETHNICITY on the human study's QUOTA definitions, which is a 3-way
    -- grouping, not our 6-way race_banner: Asian sits with Caucasian and Other
    -- rather than standing alone, and our 7 Unknown fall there too.
    CASE
      WHEN d.race_banner IN ('Hispanic')          THEN 'Hispanic/Latino'
      WHEN d.race_banner IN ('African American')  THEN 'AA/Black'
      ELSE 'Caucasian/Asian/Other'
    END                                                          AS ethnicity_w
  FROM `${PROJECT_ID}.${DS_CUR}.dim_archetype` AS d
)

SELECT archetype_id, cut_name, cut_value, comparability
FROM (
  SELECT
    a.archetype_id,
    c.cut_name,
    c.cut_value,
    c.comparability
  FROM a
  LEFT JOIN r USING (archetype_id)
  CROSS JOIN UNNEST([
    STRUCT('TOTAL'          AS cut_name, 'Total'          AS cut_value, 'demographic' AS comparability),
    STRUCT('CONCEPT',        a.creative,                               'demographic'),
    STRUCT('GENDER',         a.gender_w,                               'demographic'),
    STRUCT('QUADRANTS',      CONCAT(a.gender_w, IF(a.under35, ' <35', ' 35+')), 'demographic'),
    STRUCT('AGE BREAKOUT',   a.age_w,                                  'demographic'),
    STRUCT('MEN AGE DETAIL', IF(a.gender_w = 'Men', CONCAT('Men ', a.age_w), NULL), 'demographic'),
    STRUCT('ETHNICITY',      a.ethnicity_w,                            'demographic'),

    -- VGFRAN1 Fatal Fury: 1 know a lot, 2 a little, 3 heard of, 4 never heard.
    -- Labels verified verbatim identical to the W-Tabs' own row labels.
    STRUCT('FF FAMILIARITY', CASE r.ff_familiarity
                               WHEN 1 THEN 'Know a lot'  WHEN 2 THEN 'Know a little'
                               WHEN 3 THEN 'Heard of'    WHEN 4 THEN 'Never Heard of'
                             END,                                     'behavioural'),
    -- The W-Tabs' own nets: Total Know = punches 1-2, Non-Players = 3-4.
    -- Confirmed arithmetically against their bases (111+171=282 'Total Know').
    STRUCT('FF FAMILIARITY', CASE WHEN r.ff_familiarity IN (1, 2) THEN 'Total Know'
                                  WHEN r.ff_familiarity IN (3, 4) THEN 'Non-Players'
                             END,                                     'behavioural'),

    STRUCT('FF FANSHIP',     CASE r.ff_fanship
                               WHEN 1 THEN 'Very Much Fan' WHEN 2 THEN 'Somewhat Fan'
                               WHEN 3 THEN 'Not a Fan'
                             END,                                     'behavioural'),
    STRUCT('FF FANSHIP',     IF(r.ff_fanship IN (1, 2), 'Total Fans', NULL), 'behavioural'),

    -- GENRE FANS is P1 @ GFAN1 — punch 1 only, 'One of my favorites'.
    STRUCT('GENRE FANS',     IF(r.gfan_action  = 1, 'Action',       NULL), 'behavioural'),
    STRUCT('GENRE FANS',     IF(r.gfan_martial = 1, 'Martial Arts', NULL), 'behavioural'),
    STRUCT('GENRE FANS',     IF(r.gfan_anime   = 1, 'Anime',        NULL), 'behavioural'),

    STRUCT('GAMING',         CASE WHEN r.act_games = 1 THEN 'Daily'
                                  WHEN r.act_games BETWEEN 2 AND 5 THEN 'Weekly/Monthly'
                             END,                                     'behavioural'),

    -- MOVIEGOING. The W-Tabs print their own 'NET: Weekly/Monthly' row on the
    -- theatre item, which fixes the boundary at punches 1-3 (Every day / Every
    -- week / Every month). Punch 6 'Never' is the F10 screen-out and gets no
    -- row, so this family covers 396, not 398.
    STRUCT('MOVIEGOING',     CASE WHEN r.act_theatre BETWEEN 1 AND 3 THEN 'Weekly/Monthly'
                                  WHEN r.act_theatre BETWEEN 4 AND 5 THEN 'Every 2-6 Months'
                             END,                                     'behavioural'),

    STRUCT('POSTINT',        CASE r.postint
                               WHEN 1 THEN 'Definitely' WHEN 2 THEN 'Probably'
                               WHEN 3 THEN 'Prob/Def Not' WHEN 4 THEN 'Prob/Def Not'
                             END,                                     'behavioural')
  ]) AS c
)
WHERE cut_value IS NOT NULL;
