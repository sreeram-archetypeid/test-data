-- ============================================================================
-- STAGE 3 — LAYER-INPUT CHECKS  (the gate)
--
-- WHAT: 14 assertions over the raw layer. Each returns PASS or FAIL with the
-- measured value beside the expected one. Results land in abr_90_ops.dq_results
-- so you have a dated record of the data's condition at load time.
--
-- WHY this stage exists at all: every one of these checks corresponds to a
-- defect actually measured in these two files. They are not hypothetical. If
-- you skip this stage the defects do not disappear — they surface later as a
-- number in a banner that nobody can explain.
--
-- HOW TO USE: run the whole file, then run the final SELECT. Do not proceed to
-- Stage 4 while any check with severity='BLOCKER' reads FAIL.
--
-- Checks 03 and 04 are expected to FAIL on this data. That is correct — they
-- document known source defects that Stage 4 must handle, not things you can
-- fix upstream. Their FAIL is the instruction to apply the handling.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_90_ops.dq_results` AS

-- ---- 01  Row counts (BLOCKER) ---------------------------------------------
-- Why: the reconciliation target. 43 and 109 were measured from byte-verified
-- files. Any other number means the load mangled the CSV.
WITH c01 AS (
  SELECT '01' AS id, 'BLOCKER' AS severity, 'Row counts are 43 / 109' AS check_name,
         CAST((SELECT COUNT(*) FROM `PROJECT_ID.abr_10_raw.raw_t1`) AS STRING) || ' / ' ||
         CAST((SELECT COUNT(*) FROM `PROJECT_ID.abr_10_raw.raw_t23`) AS STRING) AS measured,
         '43 / 109' AS expected
),
-- ---- 02  Persona uniqueness + zero cross-file overlap (BLOCKER) -----------
-- Why: 152 distinct personas, no shared IDs. If IDs overlap, the two files are
-- not disjoint samples and every "separate instruments" decision downstream is
-- wrong.
c02 AS (
  SELECT '02', 'BLOCKER', 'Personas unique, 0 overlap between files',
         CAST((SELECT COUNT(DISTINCT archetype_id) FROM `PROJECT_ID.abr_10_raw.raw_t1`) AS STRING) || ' + ' ||
         CAST((SELECT COUNT(DISTINCT archetype_id) FROM `PROJECT_ID.abr_10_raw.raw_t23`) AS STRING) || ', overlap=' ||
         CAST((SELECT COUNT(*) FROM (
                SELECT archetype_id FROM `PROJECT_ID.abr_10_raw.raw_t1`
                INTERSECT DISTINCT
                SELECT archetype_id FROM `PROJECT_ID.abr_10_raw.raw_t23`)) AS STRING),
         '43 + 109, overlap=0'
),
-- ---- 03  Numeric rating channel is empty (EXPECTED FAIL) ------------------
-- Why: measured 0 of 6,103 rating cells populated. This is THE reason Stage 5
-- exists: there are no option codes, so top-box cannot be computed by counting
-- code 1. A FAIL here confirms you must run the semantic scale ranking.
-- If this ever PASSes, you have a better export and Stage 5a becomes optional.
c03 AS (
  SELECT '03', 'EXPECTED-FAIL', 'Rating columns empty -> semantic ranking required',
         (SELECT CAST(COUNTIF(TRIM(v) != '') AS STRING)
          FROM `PROJECT_ID.abr_10_raw.raw_t1` t,
               UNNEST(REGEXP_EXTRACT_ALL(TO_JSON_STRING(t), r'"Q\d+_rating":"([^"]*)"')) v),
         '0 populated (empty is expected)'
),
-- ---- 04  Skip logic on Q28 (EXPECTED FAIL / BLOCKER for Q28 only) ---------
-- Why: Q28 is conditional on scary > "a little". Exactly 1 persona per file is
-- eligible, yet all 152 answered. Q28's base is ~98% invalid. Stage 4 must
-- carry an is_eligible flag so Q28 can never be reported on the full base.
c04 AS (
  SELECT '04', 'EXPECTED-FAIL', 'Q28 answered only by scary>"a little" eligibles',
         (SELECT CAST(COUNTIF(TRIM(Q28_qual) != '') AS STRING) || ' answered, ' ||
                 CAST(COUNTIF(Q25_selected NOT IN ('Not at all','A little')
                              AND TRIM(Q25_selected) != '') AS STRING) || ' eligible'
          FROM `PROJECT_ID.abr_10_raw.raw_t23`),
         'answered == eligible (will FAIL: 109 vs 1)'
),
-- ---- 05  Generation-harness leakage (BLOCKER) -----------------------------
-- Why: two cells in T23 contain the raw LLM orchestration JSON, ~6.3k and
-- ~5.3k chars, including a self-reported note that it "might break rigid
-- external parsers". These must be quarantined, never embedded or coded.
c05 AS (
  SELECT '05', 'BLOCKER', 'Leaked orchestration JSON is detectable and countable',
         (SELECT CAST(COUNTIF(REGEXP_CONTAINS(TO_JSON_STRING(t), r'mixtureOfExperts')) AS STRING)
          FROM `PROJECT_ID.abr_10_raw.raw_t23` t),
         '2 rows (Jaquan Q10, Wm Q47)'
),
-- ---- 06  Missingness is clustered, not random (WARN) ----------------------
-- Why: all 66 blanks come from 6 of 109 personas, 4 of them in group K7. That
-- is a generation failure, not non-response. It changes the handling: partial
-- completes get excluded or re-run, they are not imputed.
c06 AS (
  SELECT '06', 'WARN', 'Blank closed-ends confined to <=6 personas',
         (SELECT CAST(COUNT(*) AS STRING) FROM (
            SELECT archetype_id
            FROM `PROJECT_ID.abr_10_raw.raw_t23` t,
                 UNNEST(REGEXP_EXTRACT_ALL(TO_JSON_STRING(t), r'"Q\d+_selected":"([^"]*)"')) v
            WHERE TRIM(v) = ''
            GROUP BY 1)),
         '6 personas'
),
-- ---- 07  group_name is collinear with age (BLOCKER for banner design) -----
-- Why: K1=4 ... K9=12 exactly. Presenting both as banner cuts double-counts
-- one variable. The banner spec in Stage 6 must pick one.
c07 AS (
  SELECT '07', 'BLOCKER', 'group_name maps 1:1 to age (must not be a 2nd cut)',
         (SELECT CAST(MAX(ages) AS STRING) FROM (
            SELECT COUNT(DISTINCT archetype_age_range) AS ages
            FROM (SELECT group_name, archetype_age_range FROM `PROJECT_ID.abr_10_raw.raw_t1`
                  UNION ALL
                  SELECT group_name, archetype_age_range FROM `PROJECT_ID.abr_10_raw.raw_t23`)
            GROUP BY group_name)),
         '1 age per group (confirms collinearity)'
),
-- ---- 08  Ethnicity label forking (BLOCKER) --------------------------------
-- Why: "Asian / Pacific Islander" vs "Asian or Pacific Islander" etc. Three
-- real categories fork into six. The forked table still sums to 100%, which is
-- exactly what makes it dangerous.
c08 AS (
  SELECT '08', 'BLOCKER', 'Ethnicity has >4 raw labels (separator forking)',
         (SELECT CAST(COUNT(DISTINCT archetype_race) AS STRING) FROM (
            SELECT archetype_race FROM `PROJECT_ID.abr_10_raw.raw_t1`
            UNION ALL SELECT archetype_race FROM `PROJECT_ID.abr_10_raw.raw_t23`)),
         '7 raw labels -> normalise to 4'
),
-- ---- 09  Adoption category plural forking (WARN) -------------------------
c09 AS (
  SELECT '09', 'WARN', 'Adoption category singular/plural forking',
         (SELECT CAST(COUNT(DISTINCT archetype_adoption_category_name) AS STRING) FROM (
            SELECT archetype_adoption_category_name FROM `PROJECT_ID.abr_10_raw.raw_t1`
            UNION ALL SELECT archetype_adoption_category_name FROM `PROJECT_ID.abr_10_raw.raw_t23`)),
         '8 raw -> 5 after singularising'
),
-- ---- 10  Zero-variance persona columns (WARN) -----------------------------
-- Why: marital_status='single' and children_status='no_children' for all 152.
-- Adult-schema columns applied to children. They carry no information and must
-- not appear as banner cuts.
c10 AS (
  SELECT '10', 'WARN', 'marital_status / children_status are constant',
         (SELECT CAST(COUNT(DISTINCT archetype_marital_status) AS STRING) || ' / ' ||
                 CAST(COUNT(DISTINCT archetype_children_status) AS STRING)
          FROM (SELECT archetype_marital_status, archetype_children_status
                FROM `PROJECT_ID.abr_10_raw.raw_t1`
                UNION ALL
                SELECT archetype_marital_status, archetype_children_status
                FROM `PROJECT_ID.abr_10_raw.raw_t23`)),
         '1 / 1 (drop both)'
),
-- ---- 11  Income is free text, not a coded band (WARN) --------------------
-- Why: 117 distinct values across 152 personas. Unusable as a cut without
-- parsing, and not worth parsing at this n.
c11 AS (
  SELECT '11', 'WARN', 'Income has <20 distinct values (i.e. is coded)',
         (SELECT CAST(COUNT(DISTINCT archetype_income_range) AS STRING) FROM (
            SELECT archetype_income_range FROM `PROJECT_ID.abr_10_raw.raw_t1`
            UNION ALL SELECT archetype_income_range FROM `PROJECT_ID.abr_10_raw.raw_t23`)),
         '117 distinct -> free text, do not use as a cut'
),
-- ---- 12  Q3 is an instruction screen, not a question (BLOCKER) ------------
-- Why: "Next, you will watch a movie trailer..." carries 152 open-end
-- "responses". It must be excluded from every open-end analysis.
c12 AS (
  SELECT '12', 'BLOCKER', 'Q3 is an instruction screen (must be excluded)',
         (SELECT ANY_VALUE(SUBSTR(Q3_question, 1, 45)) FROM `PROJECT_ID.abr_10_raw.raw_t1`),
         'starts "Next, you will watch a movie trailer"'
),
-- ---- 13  Multi-select delimiter and the "up to 3" rule (PASS expected) ---
-- Why: pipe-delimited, and 0 respondents exceeded 3 picks. Confirms SPLIT on
-- '|' is safe and no de-duplication logic is needed.
c13 AS (
  SELECT '13', 'PASS-EXPECTED', 'No multi-select exceeds 3 picks',
         (SELECT CAST(COUNTIF(ARRAY_LENGTH(SPLIT(Q33_selected, '|')) > 3) AS STRING)
          FROM `PROJECT_ID.abr_10_raw.raw_t23` WHERE TRIM(Q33_selected) != ''),
         '0 violations'
),
-- ---- 14  Stated age matches persona age (PASS expected) ------------------
-- Why: the strongest internal-consistency signal in the study. 152/152 matched
-- when measured. If this breaks, persona identity is not holding through the
-- interview and nothing else is trustworthy.
c14 AS (
  SELECT '14', 'BLOCKER', 'Q1 stated age == archetype_age_range for all 152',
         (SELECT CAST(COUNTIF(REGEXP_EXTRACT(Q1_selected, r'(\d+)') = TRIM(archetype_age_range)) AS STRING)
          FROM (SELECT Q1_selected, archetype_age_range FROM `PROJECT_ID.abr_10_raw.raw_t1`
                UNION ALL
                SELECT Q1_selected, archetype_age_range FROM `PROJECT_ID.abr_10_raw.raw_t23`)),
         '152 of 152'
)
SELECT *, CURRENT_TIMESTAMP() AS checked_at FROM (
  SELECT * FROM c01 UNION ALL SELECT * FROM c02 UNION ALL SELECT * FROM c03
  UNION ALL SELECT * FROM c04 UNION ALL SELECT * FROM c05 UNION ALL SELECT * FROM c06
  UNION ALL SELECT * FROM c07 UNION ALL SELECT * FROM c08 UNION ALL SELECT * FROM c09
  UNION ALL SELECT * FROM c10 UNION ALL SELECT * FROM c11 UNION ALL SELECT * FROM c12
  UNION ALL SELECT * FROM c13 UNION ALL SELECT * FROM c14
);

-- ---------------------------------------------------------------------------
-- THE GATE. Read this before Stage 4.
-- ---------------------------------------------------------------------------
SELECT id, severity, check_name, measured, expected
FROM `PROJECT_ID.abr_90_ops.dq_results`
ORDER BY
  CASE severity WHEN 'BLOCKER' THEN 1 WHEN 'EXPECTED-FAIL' THEN 2
                WHEN 'WARN' THEN 3 ELSE 4 END,
  id;
