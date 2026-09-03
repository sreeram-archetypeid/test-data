-- dim_question: the stable identity of a question, plus how it may be measured.
-- Expected 91 rows, 36 metas.
--
-- Q{n} numbering is positional within a file, not a question id -- Q1 in section
-- 2.2 is a different question from Q1 in section 2.3. Stable identity is
-- (meta, question_text), hashed to question_key. Verified: 91 distinct triples
-- and zero cases where one (meta, question_text) pair carries two q_type values,
-- so hashing without q_type is safe.
--
-- metric_kind: which measure is VALID for this question
-- ----------------------------------------------------
-- Added at Phase 1 close-out. Without it, box metrics get applied to questions
-- where option_code is a category id rather than a rank, producing numbers that
-- look fine and mean nothing. Measured classification over all 91:
--
--   ordinal_scale    54   closed, single-punch, scale_max > 1   -> box metrics valid
--   categorical      15   ELEMENT1 (per the QRE)                -> percentages only
--                     +1  GENDER (section 1.4)                  -> percentages only
--   multi_select      9   any row with more than one pick       -> incidence only
--   single_option     2   scale_max = 1                         -> base counts only
--   numeric_rating    1   q_type 2                              -> mean rating
--   open_end         10   q_type 1                              -> verbatim coding
--
-- The 9 multi_select are AUD2, CHARDES, ELEMENT2, GENREFIT, PLATFORM, SEEWITH,
-- SOCIAL, STORYDES and Screener 1. CHARDES ("which words describe Terry
-- Bogard"), STORYDES and ELEMENT2 are core concept-test deliverables, which is
-- why excluding them was not an option -- they needed the right metric instead.
--
-- The 2 single_option are INTRO2 (acknowledgement) and Screener 2 (country).
--
-- max_picks and max_nonsentinel are derived from stg_response directly rather
-- than from dim_question_option, so the two dimensions stay independently
-- rebuildable. scale_max deliberately lives only in dim_question_option -- one
-- source of truth.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_question` AS
WITH base AS (
  SELECT DISTINCT question_key, meta, question_text, q_type
  FROM `${PROJECT_ID}.${DS_STG}.stg_response`
),
picks AS (
  SELECT question_key, MAX(ARRAY_LENGTH(selected_options)) AS max_picks
  FROM `${PROJECT_ID}.${DS_STG}.stg_response`
  GROUP BY question_key
),
codes AS (
  SELECT r.question_key, MAX(o.option_code) AS max_nonsentinel
  FROM `${PROJECT_ID}.${DS_STG}.stg_response` AS r,
       UNNEST(r.selected_options) AS o
  WHERE o.option_code < 90
  GROUP BY r.question_key
)
SELECT
  b.question_key,
  b.meta,
  b.question_text,
  b.q_type,
  CASE b.q_type
    WHEN '1' THEN 'open_end'
    WHEN '2' THEN 'numeric_rating'
    WHEN '4' THEN 'closed_select'
    WHEN '5' THEN 'select_plus_verbatim'
  END AS question_kind,
  CASE
    WHEN b.q_type = '1'            THEN 'open_end'
    WHEN b.q_type = '2'            THEN 'numeric_rating'
    -- F9: ELEMENT1 is categorical, not ordinal. The QRE reads
    -- [SINGLE SELECT] [ROTATE P1 & P2] over Increases / Decreases / Does not
    -- change [ANCHOR]. Rotating punches 1 and 2 proves they are opposing
    -- categories rather than adjacent scale points, and punch 3 is anchored
    -- last as the neutral. So MEAN, BOT and B2B are not defined here; report
    -- three percentages instead. This cannot be inferred from the data -- the
    -- questionnaire is the only source -- hence the explicit meta.
    WHEN b.meta = 'ELEMENT1'       THEN 'categorical'
    -- Same reasoning as ELEMENT1, for the same reason it cannot be inferred
    -- from the data. GENDER's punches are Man / Woman: two labels, not two
    -- points on a scale. Left to fall through, it lands on ordinal_scale
    -- (single-punch, max code 2) and the metric layer then computes a top box,
    -- a bottom box and a MEAN of 1.4 -- numbers that look fine and mean
    -- nothing. Percentages are the only defined measure.
    WHEN b.meta = 'GENDER'         THEN 'categorical'
    WHEN p.max_picks > 1           THEN 'multi_select'
    WHEN c.max_nonsentinel = 1     THEN 'single_option'
    ELSE 'ordinal_scale'
  END AS metric_kind
FROM base AS b
LEFT JOIN picks AS p USING (question_key)
LEFT JOIN codes AS c USING (question_key);
