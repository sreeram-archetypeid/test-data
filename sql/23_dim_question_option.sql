-- dim_question_option: the option universe per question, with per-question
-- scale_max. Expected 334 rows.
--
-- Grain verified clean against source: each (question_key, option_code) pair
-- carries exactly one label and one display position, so this is genuinely one
-- row per option.
--
-- D9: codes >= 90 are sentinels ('99. None of the above') and are excluded from
-- scale_max. Only 3 of the 80 closed questions carry one -- Screener 1,
-- PLATFORM and SOCIAL -- which is precisely why F5 mattered: reading the
-- position prefix instead of the code prefix would have hidden all three and
-- inflated their scale_max to 9 / 6 / 17 instead of 8 / 5 / 15.
--
-- scale_max is per question, never hardcoded. Observed values across the 71
-- single-select ordinal questions are {1, 2, 3, 4, 6} -- note there is no
-- 5-point scale anywhere in this study, so any hand-built formula assuming one
-- is wrong on every question.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_question_option` AS
WITH opts AS (
  SELECT DISTINCT
    r.question_key,
    o.option_code,
    o.option_position,
    o.option_label
  FROM `${PROJECT_ID}.${DS_STG}.stg_response` AS r,
       UNNEST(r.selected_options) AS o
  WHERE o.option_code IS NOT NULL
)
SELECT
  question_key,
  option_code,
  option_position,
  option_label,
  option_code >= 90 AS is_sentinel,
  MAX(IF(option_code >= 90, NULL, option_code))
    OVER (PARTITION BY question_key) AS scale_max
FROM opts;
