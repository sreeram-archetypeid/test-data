-- ============================================================================
-- STAGE 4b — the unpivot: wide (312/333 cols) -> long (fct_response)
--
-- WHAT: a stored procedure that reads abr_90_ops.column_inventory and builds
-- the UNION ALL that turns each Q<n>_* column group into rows.
--
-- WHY generated and not hand-written: T1 carries 38 questions and T23 carries
-- 41, and they are DIFFERENT question numbers (T1 has the odd branch Q5-Q21,
-- T23 the even branch Q6-Q22). Hand-writing ~79 blocks invites exactly the
-- kind of copy-paste slip that silently drops one question from one file.
-- The procedure cannot make that mistake, and it re-adapts if the source ever
-- changes shape.
--
-- WHY a fact table at all: everything downstream — top-box, banners, semantic
-- coding, BQML features — is one GROUP BY away once the data is long. In wide
-- form each of those needs 79 hand-written column references.
--
-- Replace PROJECT_ID throughout, then: CALL abr_20_curated.sp_build_fct_response();
-- ============================================================================

CREATE OR REPLACE PROCEDURE `PROJECT_ID.abr_20_curated.sp_build_fct_response`()
BEGIN
  DECLARE sql_text STRING;

  -- Build one SELECT block per (instrument, question), then UNION them.
  -- Each block pulls the 7 sibling columns for that question number.
  SET sql_text = (
    SELECT STRING_AGG(block, '\nUNION ALL\n' ORDER BY instrument, qnum)
    FROM (
      SELECT
        instrument,
        SAFE_CAST(question_num AS INT64) AS qnum,
        FORMAT("""
SELECT
  archetype_id,
  '%s'                       AS instrument,
  'Q%s'                      AS question_key,
  %s                         AS question_num,
  Q%s_question               AS question_text,
  Q%s_meta                   AS question_meta,
  Q%s_type                   AS question_type_code,
  CASE Q%s_type WHEN '1' THEN 'open_end'
                WHEN '4' THEN 'single_select'
                WHEN '5' THEN 'multi_select'
                ELSE 'unknown' END AS question_type,
  NULLIF(TRIM(Q%s_selected), '') AS selected_raw,
  NULLIF(TRIM(Q%s_qual), '')     AS qual_raw,
  NULLIF(TRIM(Q%s_rating), '')   AS rating_raw
FROM `PROJECT_ID.abr_10_raw.raw_%s`""",
          instrument, question_num, question_num,
          question_num, question_num, question_num, question_num,
          question_num, question_num, question_num,
          LOWER(instrument)) AS block
      FROM `PROJECT_ID.abr_90_ops.column_inventory`
      WHERE column_class = 'question' AND question_field = 'question'
    )
  );

  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE TABLE `PROJECT_ID.abr_20_curated.fct_response`
    CLUSTER BY instrument, question_key AS
    WITH long AS (%s)
    SELECT
      l.archetype_id,
      l.instrument,
      l.question_key,
      l.question_num,
      l.question_text,
      l.question_meta,
      l.question_type,
      l.selected_raw,
      l.qual_raw,
      l.rating_raw,

      -- ------------------------------------------------------------------
      -- Multi-select: pipe-delimited, verified 0 rows exceed 3 picks
      -- (check 13), so a plain SPLIT is safe.
      -- ------------------------------------------------------------------
      CASE WHEN l.question_type = 'multi_select'
           THEN SPLIT(l.selected_raw, '|') END        AS selected_array,
      CASE WHEN l.question_type = 'multi_select'
           THEN ARRAY_LENGTH(SPLIT(l.selected_raw, '|')) END AS n_picks,

      -- ------------------------------------------------------------------
      -- Normalised grouping key for closed-ends.
      -- WHY: T23 Q16 reads 'A little bit.' while Q18 reads 'A little bit'
      -- (check on label drift), and three labels carry a curly apostrophe
      -- (U+2019). Grouping on the raw string forks those into separate
      -- banner rows. Group on this key; DISPLAY selected_raw.
      -- ------------------------------------------------------------------
      CASE WHEN l.question_type = 'single_select'
           THEN LOWER(TRIM(REGEXP_REPLACE(
                  REPLACE(l.selected_raw, '\\u2019', ''''),
                  r'[.!]+$', '')))
      END                                             AS selected_norm,

      -- ------------------------------------------------------------------
      -- Open-end cleaning. Stage 5 depends on this and nothing else should
      -- use qual_raw for analysis.
      --   qual_clean  : stage directions and *actions* stripped
      --   is_leaked   : the 2 orchestration-JSON cells (check 05)
      --   is_fatigued : simulated survey fatigue, which rises to 45%% by Q50
      --   is_instruction : Q3, which is not a question at all (check 12)
      -- ------------------------------------------------------------------
      CASE WHEN l.question_type = 'open_end' THEN
        TRIM(REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(IFNULL(l.qual_raw, ''), r'\\[[^\\]]*\\]', ' '),
            r'\\*[^*]*\\*', ' '),
          r'\\s+', ' '))
      END                                             AS qual_clean,

      REGEXP_CONTAINS(IFNULL(l.qual_raw,''), r'mixtureOfExperts|"targetLanguage"')
        OR LENGTH(IFNULL(l.qual_raw,'')) > 3000       AS is_leaked,

      REGEXP_CONTAINS(LOWER(IFNULL(l.qual_raw,'')),
        r"tired|are we done|can i go|brain is tired|hands are tired|no more question")
                                                      AS is_fatigued,

      (l.question_key = 'Q3')                         AS is_instruction,

      -- ------------------------------------------------------------------
      -- Q28/Q29 eligibility (check 04). Q28 is conditional on scary >
      -- 'a little'; 151 of 152 answered it anyway. This flag is what stops
      -- Q28 ever being reported on the full base.
      -- ------------------------------------------------------------------
      CASE WHEN l.question_key IN ('Q28','Q29')
           THEN COALESCE(s.scary_norm NOT IN ('not at all','a little'), FALSE)
           ELSE TRUE END                              AS is_base_eligible,

      CURRENT_TIMESTAMP()                             AS built_at
    FROM long l
    LEFT JOIN (
      SELECT archetype_id,
             LOWER(TRIM(REGEXP_REPLACE(selected_raw, r'[.!]+$',''))) AS scary_norm
      FROM long WHERE question_key = 'Q25'
    ) s USING (archetype_id)
  """, sql_text);
END;

-- Run it:
-- CALL `PROJECT_ID.abr_20_curated.sp_build_fct_response`();

-- ---------------------------------------------------------------------------
-- GATE. Expected: 152 personas; T1 = 38 questions x 43 = 1,634 rows,
-- T23 = 41 x 109 = 4,469 rows; total 6,103. That 6,103 is the same number as
-- the empty rating cells in check 03 — same grid, viewed two ways.
-- ---------------------------------------------------------------------------
SELECT instrument,
       COUNT(*)                            AS fact_rows,
       COUNT(DISTINCT archetype_id)        AS personas,
       COUNT(DISTINCT question_key)        AS questions,
       COUNTIF(question_type='open_end')   AS open_end_rows,
       COUNTIF(is_leaked)                  AS leaked_rows,
       COUNTIF(NOT is_base_eligible)       AS ineligible_rows
FROM `PROJECT_ID.abr_20_curated.fct_response`
GROUP BY instrument
ORDER BY instrument;
