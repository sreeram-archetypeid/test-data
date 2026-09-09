-- ============================================================================
-- Stage 11 (optional): AI ranking for the questions stage 5 could not settle.
-- ============================================================================
-- It is pointed at abr_20_curated.dim_question_review ONLY. In the current wave
-- that is 5 questions of 131. Sending all 131 costs more and invites drift on
-- the 126 the printed scale point already pins -- a question resolved by the
-- questionnaire's own scale does not need a model's opinion.
--
-- temperature 0, and the prompt text lives in this file, in git. A prompt edited
-- outside version control re-ranks the study and nothing in the output looks
-- different.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.ai_scale_rank` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_40_semantic.gemini_flash`,
  (
    SELECT
      run_id, question_key, panel, meta, flags,
      CONCAT(
        'You are equating survey scales for a film-trailer concept test.\n\n',
        'Question (', panel, ', ', meta, '): ', question_text, '\n\n',
        'Options as exported (the leading number is an export code whose direction ',
        'is NOT reliable; some labels print their own scale point):\n',
        option_block, '\n\n',
        'Rank these options from most favourable to the film (rank 1) to least ',
        'favourable. Judge favourability toward the film, not intensity of the word: ',
        'for a question about something undesirable (boring, scary, confusing, too ',
        'long), "Not at all" is the MOST favourable answer. For "too little / the ',
        'right amount / too much" items, "the right amount" is most favourable and ',
        'both extremes are less so.\n',
        'Mark any option outside the ordered scale (do not know, not sure, other, ',
        'something else, none of the above, prefer not to say) as sentinel = true; ',
        'sentinels get no rank.\n',
        'If the option list does not match what the question asks, return ',
        'sentinel = true for every option and say so in reasoning.'
      ) AS prompt
    FROM `PROJECT_ID.abr_20_curated.dim_question_review`
  ),
  STRUCT(
    'option_raw STRING, rank INT64, sentinel BOOL, latent_favourability FLOAT64, reasoning STRING'
      AS output_schema,
    0.0 AS temperature
  )
);

-- ---------------------------------------------------------------------------
-- Validate BEFORE any mart uses it. A ranking that fails these is a bug.
-- ---------------------------------------------------------------------------
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT question_key,
           COUNTIF(NOT sentinel) AS n_ranked,
           COUNT(DISTINCT IF(NOT sentinel, rank, NULL)) AS n_distinct,
           MAX(IF(NOT sentinel, rank, NULL)) AS mx
    FROM `PROJECT_ID.abr_40_semantic.ai_scale_rank`
    GROUP BY question_key
    HAVING n_ranked != n_distinct OR mx != n_ranked
  )
) = 0 AS 'AI ranking is not a strict 1..n permutation for some question';

ASSERT (
  SELECT COUNT(*)
  FROM `PROJECT_ID.abr_40_semantic.ai_scale_rank` a
  JOIN `PROJECT_ID.abr_40_semantic.ai_scale_rank` b
    USING (question_key)
  WHERE a.rank < b.rank AND NOT a.sentinel AND NOT b.sentinel
    AND a.latent_favourability <= b.latent_favourability
) = 0 AS 'AI latent favourability is not monotonic in rank';

-- Stability: run this file a second time into ai_scale_rank_run2 and require the
-- two to agree exactly. At temperature 0 they should. If they do not, the model
-- is not a stable instrument for this task and the deterministic ranking stands.
--
--   CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.ai_scale_rank_run2` AS
--   SELECT * FROM AI.GENERATE_TABLE( ... same query ... );
--
-- ASSERT (
--   SELECT COUNT(*) FROM `PROJECT_ID.abr_40_semantic.ai_scale_rank` a
--   FULL JOIN `PROJECT_ID.abr_40_semantic.ai_scale_rank_run2` b
--     USING (question_key, option_raw)
--   WHERE a.rank IS DISTINCT FROM b.rank OR a.sentinel IS DISTINCT FROM b.sentinel
-- ) = 0 AS 'AI ranking is not stable across two runs at temperature 0';

-- Where stage 5 DID resolve a question, the model must agree. Disagreement means
-- one of the two is wrong; look at the sentence before overriding either.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_semantic.v_scale_disagreement` AS
SELECT d.run_id, d.question_key, d.meta, d.option_raw, d.option_label,
       d.rank_basis, d.favourability_rank AS deterministic_rank, a.rank AS ai_rank,
       a.reasoning
FROM `PROJECT_ID.abr_20_curated.dim_question_option_scaled` d
JOIN `PROJECT_ID.abr_40_semantic.ai_scale_rank` a
  USING (run_id, question_key, option_raw)
WHERE d.rank_basis IN ('printed_scale_point', 'lexicon')
  AND d.favourability_rank IS DISTINCT FROM a.rank;
