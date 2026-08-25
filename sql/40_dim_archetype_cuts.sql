-- dim_archetype_cuts: persona-level behavioural flags for the banner cuts that
-- come from RESPONSES rather than from persona attributes. Expected 398 rows.
--
-- The banner plan defines two families of cut. Demographic cuts (gender, age,
-- race, income, relationship, parent) come straight off dim_archetype. The
-- behavioural cuts below are top-box on specific questions, so they have to be
-- collapsed to one row per persona before they can be used as a column.
--
-- Every flag reads v_response_metrics WHERE is_primary_run: without it the
-- replicated section 2.1 questions double-count 198 personas.
--
-- These are all TOP BOX cuts, and is_tb anchors at option_code = 1 rather than
-- at scale_max, so none of them were affected by the F8 scale correction.
--
-- Filtering on question_text as well as meta is deliberate: GFAN1 and VGFRAN1
-- are batteries of 8 and 11 items, so meta alone would collapse every genre or
-- franchise into one flag.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_MART}.dim_archetype_cuts` AS
SELECT
  a.archetype_id,

  -- MOVIE GENRE FANS: TOP BOX (banner plan AY9)
  LOGICAL_OR(m.meta = 'GFAN1'   AND m.question_text LIKE '%Martial Arts%' AND m.is_tb)
    AS cut_fan_martial_arts,
  LOGICAL_OR(m.meta = 'GFAN1'   AND m.question_text LIKE '%Anim%'         AND m.is_tb)
    AS cut_fan_anime,

  -- MEDIA BEHAVIORS: TOP BOX ONLY (banner plan AI9)
  LOGICAL_OR(m.meta = 'ACTIVITIES' AND m.question_text LIKE '%theater%'      AND m.is_tb)
    AS cut_heavy_cinema,
  LOGICAL_OR(m.meta = 'ACTIVITIES' AND m.question_text LIKE '%video games%'  AND m.is_tb)
    AS cut_heavy_gamer,
  LOGICAL_OR(m.meta = 'ACTIVITIES' AND m.question_text LIKE '%stream%'       AND m.is_tb)
    AS cut_heavy_streamer,
  LOGICAL_OR(m.meta = 'ACTIVITIES' AND m.question_text LIKE '%social media%' AND m.is_tb)
    AS cut_heavy_social,

  -- VIDEO GAME TITLE APPEAL: TOP BOX ONLY (banner plan AO9)
  LOGICAL_OR(m.meta = 'VGFRAN1' AND m.question_text LIKE '%Fatal Fury%'      AND m.is_tb)
    AS cut_knows_fatal_fury,
  LOGICAL_OR(m.meta = 'VGFRAN1' AND m.question_text LIKE '%Mortal Kombat%'   AND m.is_tb)
    AS cut_knows_mortal_kombat,
  LOGICAL_OR(m.meta = 'VGFRAN1' AND m.question_text LIKE '%Street Fighter%'  AND m.is_tb)
    AS cut_knows_street_fighter,

  -- TOP BOX (banner plan AG9)
  LOGICAL_OR(m.meta = 'POSTINT' AND m.is_tb) AS cut_postint_tb,
  LOGICAL_OR(m.meta = 'AUD3'    AND m.is_tb) AS cut_aud3_tb,
  LOGICAL_OR(m.meta = 'URG1'    AND m.is_tb) AS cut_urg1_tb

FROM `${PROJECT_ID}.${DS_CUR}.dim_archetype` AS a
LEFT JOIN `${PROJECT_ID}.${DS_CUR}.v_response_metrics` AS m
  ON m.archetype_id = a.archetype_id
 AND m.is_primary_run
GROUP BY a.archetype_id;
