-- ============================================================================
-- Stage 14 (optional): AI scoring of the prose-only metrics.
-- ============================================================================
-- Run stage 7 first. It gives you the expected distribution per metric from a
-- rubric you can read, so when this pass returns a top box 20 points away you
-- know to look at the prompt rather than at the film.
--
-- Point it at the metrics where the two independent readings already DISAGREE.
-- In the current wave the rubric and the generator's own aat verdict agree on
-- overall appeal for 98% of personas and on theatrical intent for 75% -- so
-- theatrical intent is where a third opinion is worth paying for.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.ai_prose_score` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_40_semantic.gemini_flash`,
  (
    SELECT
      p.run_id, p.archetype_id, p.meta, p.question_text, p.text,
      CONCAT(
        'A respondent answered a scale question in prose. Place the answer on the ',
        '5-point scale below, using only what the answer says.\n\n',
        'Scale:\n',
        '  5 = definitely / very positive\n',
        '  4 = probably / positive\n',
        '  3 = neutral or conditional\n',
        '  2 = probably not / negative\n',
        '  1 = definitely not / very negative\n\n',
        'Rules: a conditional answer ("if the reviews are good") is 3. An answer ',
        'that defers to home viewing ("I would wait for streaming") is 2 for a ',
        'theatrical question, not a 4. An answer that says the question does not ',
        'apply ("N/A, I am a parent") returns score = NULL with confidence = ',
        '"not_applicable". Quote the span you scored from.\n\n',
        'Question: ', p.question_text, '\nAnswer: ', p.text
      ) AS prompt
    FROM `PROJECT_ID.abr_30_marts.prose_score` p
    -- start with the metric where the two readings disagree most:
    -- WHERE p.meta = 'DTHEAT'
  ),
  STRUCT(
    'score INT64, confidence STRING, evidence_span STRING' AS output_schema,
    0.0 AS temperature
  )
);

-- Three independent readings of the same construct, side by side. Where all
-- three agree you can publish; where they do not, the disagreement IS the
-- finding and belongs in the report rather than being averaged away.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_semantic.v_prose_triangulation` AS
SELECT
  p.run_id, p.meta,
  COUNT(*) AS base,
  ROUND(100.0 * COUNTIF(p.score = 5) / NULLIF(COUNTIF(p.score IS NOT NULL), 0), 1)
    AS rubric_top_box_pct,
  ROUND(100.0 * COUNTIF(a.score = 5) / NULLIF(COUNTIF(a.score IS NOT NULL), 0), 1)
    AS ai_top_box_pct,
  ROUND(100.0 * COUNTIF(p.aat_score = 5) / NULLIF(COUNTIF(p.aat_score IS NOT NULL), 0), 1)
    AS aat_top_box_pct,
  ROUND(100.0 * COUNTIF(ABS(p.score - a.score) <= 1)
        / NULLIF(COUNTIF(p.score IS NOT NULL AND a.score IS NOT NULL), 0), 1)
    AS rubric_vs_ai_agreement_pct
FROM `PROJECT_ID.abr_30_marts.prose_score` p
LEFT JOIN `PROJECT_ID.abr_40_semantic.ai_prose_score` a
  USING (run_id, archetype_id, meta)
GROUP BY p.run_id, p.meta;

-- The rows a human should actually look at: where the rubric and the model are
-- two or more points apart.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_semantic.v_prose_disagreement` AS
SELECT p.run_id, p.meta, p.archetype_id,
       p.score AS rubric_score, a.score AS ai_score, p.aat_score,
       p.evidence AS rubric_cue, a.evidence_span, p.text
FROM `PROJECT_ID.abr_30_marts.prose_score` p
JOIN `PROJECT_ID.abr_40_semantic.ai_prose_score` a
  USING (run_id, archetype_id, meta)
WHERE ABS(p.score - a.score) >= 2
ORDER BY ABS(p.score - a.score) DESC;
