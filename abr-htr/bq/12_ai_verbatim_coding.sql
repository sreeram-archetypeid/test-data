-- ============================================================================
-- Stage 12 (optional): AI verbatim coding, against the SAME codeframe.
-- ============================================================================
-- Run stage 6 first. It gives you an expected incidence per theme from a frame
-- you can read, so a model result 20 points away is a prompt bug you can see
-- rather than a finding you might publish.
--
-- COST CONTROL: uncomment the LIMIT and read the output before the full pass.
-- This is the one place where a wrong prompt costs real money and, worse,
-- silently wrong codes.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.ai_verbatim_code` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_40_semantic.gemini_flash`,
  (
    SELECT
      v.doc_id, v.run_id, v.archetype_id, v.panel, v.meta, v.qual_clean,
      CONCAT(
        'Code this response from a film-trailer concept test against the codeframe. ',
        'Apply every theme that genuinely appears; apply none if none do. Judge only ',
        'what the respondent said, not what you would expect them to say. A response ',
        'that declines to complain ("nothing, I loved it") gets no themes.\n\n',
        'Codeframe:\n',
        (SELECT STRING_AGG(FORMAT('  - %s: %s (%s)', theme_id, theme_label, theme_polarity), '\n'
                           ORDER BY theme_id)
         FROM (SELECT DISTINCT theme_id, theme_label, theme_polarity
               FROM `PROJECT_ID.abr_00_config.codeframe`)),
        '\n\nQuestion: ', v.question_text, '\nResponse: ', v.qual_clean
      ) AS prompt
    FROM `PROJECT_ID.abr_20_curated.v_verbatim` v
    WHERE v.n_chars >= 25 AND NOT v.is_null_response
    -- LIMIT 20   -- uncomment for the first pass
  ),
  STRUCT(
    'themes ARRAY<STRING>, sentiment STRING, is_actionable BOOL, evidence_span STRING'
      AS output_schema,
    0.0 AS temperature
  )
);

-- Reconcile against the deterministic pass before anyone quotes a number. A gap
-- over ~10 points on a common theme means the two are not coding the same
-- construct; fix that before the marts, not after.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_semantic.v_coding_reconciliation` AS
WITH base AS (
  SELECT run_id, COUNT(DISTINCT archetype_id) AS personas
  FROM `PROJECT_ID.abr_20_curated.v_verbatim` GROUP BY run_id
),
det AS (
  SELECT run_id, theme_id, COUNT(DISTINCT archetype_id) AS personas
  FROM `PROJECT_ID.abr_30_marts.verbatim_code`
  WHERE source = 'verbatim' GROUP BY run_id, theme_id
),
ai AS (
  SELECT run_id, theme AS theme_id, COUNT(DISTINCT archetype_id) AS personas
  FROM `PROJECT_ID.abr_40_semantic.ai_verbatim_code`, UNNEST(themes) AS theme
  GROUP BY run_id, theme
)
SELECT b.run_id, COALESCE(d.theme_id, a.theme_id) AS theme_id,
       ROUND(100.0 * IFNULL(d.personas, 0) / b.personas, 1) AS deterministic_pct,
       ROUND(100.0 * IFNULL(a.personas, 0) / b.personas, 1) AS ai_pct,
       ROUND(100.0 * (IFNULL(a.personas, 0) - IFNULL(d.personas, 0)) / b.personas, 1) AS gap
FROM base b
LEFT JOIN det d ON d.run_id = b.run_id
FULL JOIN ai a ON a.run_id = b.run_id AND a.theme_id = d.theme_id
ORDER BY ABS(gap) DESC;
