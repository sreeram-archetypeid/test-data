-- ============================================================================
-- STAGE 5a — SEMANTIC SCALE RANKING   ** the centrepiece **
--
-- THE PROBLEM THIS SOLVES
-- Your exports carry no numeric option codes (check 03: 0 of 6,103 rating
-- cells populated). Worse, the same construct is asked on different scales:
--     "How much did you like the trailer?"
--        T1  (ages 4-7) : 2 points  -- "I liked it a lot" / "It was okay"
--        T23 (ages 8-12): 5 points  -- "I liked it a lot!" / "I liked it!" /
--                                      "It was okay." / "I didn't like it much." /
--                                      "I did not like it."
-- Counting top box across those two produces a 37-point "decline" that is pure
-- scale artefact. And the human Vancouver benchmark uses a THIRD scale (NRG
-- 5-point, 1 = best, adult Q1 mean 2.25).
--
-- THE FIX
-- Put every option from every scale onto ONE latent 0-100 favourability axis,
-- by asking the model to rank each question's options AS A SET. Then top box
-- stops being "count the first label" and becomes "score above threshold" —
-- which is comparable across all three instruments.
--
-- THE ONE DESIGN DECISION THAT MATTERS
-- The prompt receives ALL sibling options for a question at once, in a single
-- call, and must return a complete ranking of them. Scoring an option in
-- isolation ("how positive is 'It was okay'?") is meaningless — the answer
-- depends entirely on what it was offered against. This is why the input is
-- grouped with STRING_AGG before the call rather than one row per option.
--
-- COST: ~79 questions -> ~79 calls. Trivial. Run it on the full set.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 5a.1  The option universe: every distinct closed-end label, per question
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.dim_question_option` AS
SELECT
  instrument,
  question_key,
  ANY_VALUE(question_text)                       AS question_text,
  ANY_VALUE(question_type)                       AS question_type,
  option_label,
  LOWER(TRIM(REGEXP_REPLACE(REPLACE(option_label,'’',''''), r'[.!]+$',''))) AS option_norm,
  COUNT(*)                                       AS n_selected
FROM (
  SELECT instrument, question_key, question_text, question_type,
         TRIM(opt) AS option_label
  FROM `PROJECT_ID.abr_20_curated.fct_response`,
       UNNEST(CASE WHEN question_type = 'multi_select'
                   THEN SPLIT(selected_raw, '|')
                   ELSE [selected_raw] END) AS opt
  WHERE question_type IN ('single_select','multi_select')
    AND selected_raw IS NOT NULL
)
WHERE option_label != ''
GROUP BY instrument, question_key, option_label, option_norm;


-- ---------------------------------------------------------------------------
-- 5a.2  Rank each question's options as a set
--
-- The model returns, for ONE question at a time:
--   ranked_options : options in order, best-first, pipe-delimited
--   scores         : matching 0-100 latent scores, pipe-delimited
--   scale_polarity : 'favourability' | 'intensity' | 'frequency' | 'nominal'
--   is_ordinal     : FALSE for nominal questions (e.g. "who would you watch
--                    with"), which must NOT get a top box at all
--
-- WHY ask for parallel pipe-delimited strings rather than an array of structs:
-- it keeps the output schema flat and trivially parseable, and it forces the
-- model to emit exactly as many scores as options — a mismatch is then an
-- obvious, checkable failure rather than a silent partial result.
--
-- WHY is_ordinal matters: Q45 "Who would you most want to watch with?" has no
-- best answer. Computing a top box on it is meaningless. Stage 6 refuses to.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.option_rank_raw` AS
SELECT
  instrument, question_key, question_text, n_options,
  ranked_options, scores, scale_polarity, is_ordinal, reasoning,
  'scale_rank_v1' AS prompt_id,
  CURRENT_TIMESTAMP() AS generated_at
FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_30_semantic.gemini_text`,
  (
    SELECT
      instrument, question_key, n_options,
      ANY_VALUE(question_text) AS question_text,
      CONCAT(
        'You are calibrating a survey scale for a children''s movie-trailer study.\n\n',
        'QUESTION: ', ANY_VALUE(question_text), '\n\n',
        'ANSWER OPTIONS (unordered):\n', options_block, '\n\n',
        'TASK:\n',
        '1. Decide whether these options form an ORDERED scale (most positive to ',
        'most negative, or most to least intense). Some questions are NOMINAL ',
        '(e.g. "who would you watch this with?") and have no better or worse ',
        'answer — set is_ordinal to false for those.\n',
        '2. If ordinal, return every option in order, BEST/MOST POSITIVE FIRST, ',
        'pipe-delimited, in ranked_options. Reproduce each option string EXACTLY ',
        'as given.\n',
        '3. In scores, return one 0-100 latent favourability score per option in ',
        'the SAME order, pipe-delimited. 100 = maximum possible positivity for ',
        'this construct, 0 = maximum negativity. Space the scores to reflect the ',
        'real semantic distance between options: "I liked it a lot" and "I liked ',
        'it" are close together and both high; "It was okay" sits near the ',
        'midpoint. Do NOT simply spread them evenly.\n',
        '4. Judge the options against the ABSOLUTE construct, not against each ',
        'other. A 2-point scale whose options are "I liked it a lot" and "It was ',
        'okay" must score roughly 90 and 50 — NOT 100 and 0. This is the whole ',
        'point of the exercise: a coarse scale must land on the same axis as a ',
        'fine one.\n',
        '5. Return exactly as many scores as there are options (', CAST(n_options AS STRING), ').'
      ) AS prompt
    FROM (
      SELECT instrument, question_key, question_text,
             COUNT(*) AS n_options,
             STRING_AGG(CONCAT('- ', option_label), '\n' ORDER BY option_label) AS options_block
      FROM `PROJECT_ID.abr_20_curated.dim_question_option`
      WHERE question_type = 'single_select'
      GROUP BY instrument, question_key, question_text
    )
    GROUP BY instrument, question_key, n_options, options_block
  ),
  STRUCT(
    'ranked_options STRING, scores STRING, scale_polarity STRING, is_ordinal BOOL, reasoning STRING'
      AS output_schema,
    0.0 AS temperature          -- determinism: this table IS the measurement instrument
  )
);


-- ---------------------------------------------------------------------------
-- 5a.3  Explode back to one row per option, with its latent score
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.option_scale_map` AS
SELECT
  r.instrument,
  r.question_key,
  r.question_text,
  r.scale_polarity,
  r.is_ordinal,
  r.n_options,
  opt                                                    AS option_label,
  LOWER(TRIM(REGEXP_REPLACE(REPLACE(opt,'’',''''), r'[.!]+$',''))) AS option_norm,
  pos                                                    AS rank_position,
  SAFE_CAST(TRIM(SPLIT(r.scores, '|')[SAFE_OFFSET(pos - 1)]) AS FLOAT64) AS latent_score,
  -- Raw boxes, per instrument. Correct WITHIN an instrument, never across one.
  (pos = 1)                                              AS is_raw_top_box,
  (pos <= 2)                                             AS is_raw_top2_box,
  (pos = r.n_options)                                    AS is_raw_bottom_box,
  r.prompt_id
FROM `PROJECT_ID.abr_30_semantic.option_rank_raw` r,
     UNNEST(SPLIT(r.ranked_options, '|')) AS opt WITH OFFSET off,
     UNNEST([off + 1]) AS pos
WHERE r.is_ordinal;
