-- dim_question_option: the option universe per question, with per-question
-- scale_max. Expected 334 rows.
--
-- Grain verified clean against source: each (question_key, option_code) pair
-- carries exactly one label and one display position, so this is genuinely one
-- row per option.
--
-- D9: codes >= 90 are sentinels ('99. None of the above') and are excluded from
-- scale_max. Only 3 of the 80 closed questions carry one -- Screener 1, PLATFORM
-- and SOCIAL -- which is why F5 mattered: reading the position prefix instead of
-- the code prefix would have hidden all three.
--
-- F8: scale_max is the BATTERY maximum, not the observed maximum
-- --------------------------------------------------------------
-- Deriving scale_max from the codes RESPONDENTS USED understates the scale they
-- were OFFERED whenever a battery's tail option goes unused. Measured, this hit
-- 8 questions:
--
--   ACTIVITIES  play video games      4 "Every 2-6 months"  ->  6 "Never"
--   GFAN1       Action                3 "Don't really like" ->  4 "I never see these"
--   GFAN1       Suspense/Thriller     3                     ->  4
--   GFAN1       Martial Arts          3                     ->  4
--   VGFRAN1     Mortal Kombat         3 "heard of, dont know"-> 4 "never heard of this"
--   VGFRAN1     Street Fighter        3                     ->  4
--   VGFRAN1     Super Smash Bros.     3                     ->  4
--   VGFRAN3     interest given knowledge 3 "Probably not"   ->  4 "Definitely not"
--
-- Effect on the metrics: is_tb and is_t2b are UNCHANGED (they anchor at codes 1
-- and 2, not at scale_max), so every TOP BOX banner cut was always correct.
-- is_bot drops 6,566 -> 5,960 and is_b2b drops 12,840 -> 12,000. Those 606 and
-- 840 rows were mislabelled: on the GFAN1 items, B2B spanned codes {2,3} instead
-- of {3,4}, counting "Like these a lot, but only see some" as bottom-two-box.
--
-- GFAN1 and VGFRAN1 are banner-cut sources, which is what made this worth fixing
-- rather than noting.
--
-- The battery is keyed on `meta`. Verified safe: across all ordinal questions
-- there are ZERO (meta, option_code) pairs carrying conflicting labels, so code 3
-- means the same thing for every question in a meta and the meta-wide maximum is
-- the real scale length. Applying the rule changes exactly the 8 questions above
-- and nothing else.
--
-- Residual risk, stated plainly: if an ENTIRE battery never uses its tail, this
-- still understates. `ARENA_Fatal Fury Concept Test_Programming 061926.docx` is
-- the authoritative scale source (plan doc section 1.4). scale_max_source marks
-- the 8 corrected questions so they can be verified against it rather than
-- silently trusted.
--
-- scale_max is never hardcoded. Across the 69 genuine ordinal questions the
-- universe is {2, 3, 4, 6} -- there is no 5-point scale anywhere in this study.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_question_option` AS
WITH opts AS (
  SELECT DISTINCT
    r.question_key,
    r.meta,
    o.option_code,
    o.option_position,
    o.option_label
  FROM `${PROJECT_ID}.${DS_STG}.stg_response` AS r,
       UNNEST(r.selected_options) AS o
  WHERE o.option_code IS NOT NULL
),
observed AS (
  SELECT question_key, MAX(IF(option_code >= 90, NULL, option_code)) AS observed_max
  FROM opts
  GROUP BY question_key
),
battery AS (
  SELECT meta, MAX(IF(option_code >= 90, NULL, option_code)) AS battery_max
  FROM opts
  GROUP BY meta
)
SELECT
  o.question_key,
  o.option_code,
  o.option_position,
  o.option_label,
  o.option_code >= 90 AS is_sentinel,
  b.battery_max       AS scale_max,
  IF(b.battery_max > s.observed_max, 'battery', 'observed') AS scale_max_source,
  s.observed_max
FROM opts       AS o
JOIN observed   AS s USING (question_key)
JOIN battery    AS b ON b.meta = o.meta;
