-- Data-quality suite: DQ01-DQ29, appended to ff_30_marts.dq_results.
--
-- Every assertion here encodes a defect actually found in this data. They are
-- regression tests, not hypotheticals -- and every threshold was measured from
-- the 12 source CSVs, so a red row means the pipeline changed, never that the
-- expectation was guessed.
--
-- Results are APPENDED with a run timestamp rather than replaced, so drift is
-- visible over time: a threshold that starts failing after an upstream
-- re-export is exactly the signal this table exists to give.
--
-- Three thresholds differ from the plan doc, all corrected:
--
--   DQ07  the doc asserts 81 imputed-age rows. That counts row-occurrences
--         across the 12 wide files and each persona appears in 3-4 of them.
--         Split by grain: 22 personas (dim), 2,302 rows (fct).           [F2]
--   DQ08  the doc asserts 0 type-1 rows without a verbatim; 3 are genuinely
--         blank. Pinned at 3 so the test catches drift.                  [F3]
--   DQ11  the doc asserts 0 closed questions with scale_max outside [2,12];
--         6 legitimately are. Pinned at 6, and this row is the standing
--         evidence for the deferred box-metric decision.
--
-- DQ17-DQ19 guard defects the doc did not know about: the option-code prefix
-- (F5) and the income regex (F6).
--
-- DQ20-DQ24 guard the Phase 1 close-out metric model. DQ22 is the important
-- one: it fails if a box flag ever reappears on a question where option_code
-- is a category id rather than a rank.
--
-- DQ25-DQ26 guard the F8 battery scale_max: 8 questions had their offered scale
-- understated because it was derived from the codes respondents used.
--
-- DQ27-DQ29 come from the questionnaire itself. DQ27 keeps ELEMENT1 categorical
-- (its punches rotate, so it is not a rank). DQ28 keeps the QRE routing applied:
-- 676 rows sit outside the base the questionnaire defines, and DQ28e fails if the
-- rule table and the CASE that implements it ever drift apart. DQ29 asserts the
-- flag only ever adds a column and never drops a row.

CREATE TABLE IF NOT EXISTS `${PROJECT_ID}.${DS_MART}.dq_results` (
  run_ts    TIMESTAMP,
  dq_id     STRING,
  assertion STRING,
  actual    INT64,
  expected  INT64,
  passed    BOOL
);

INSERT INTO `${PROJECT_ID}.${DS_MART}.dq_results`
  (run_ts, dq_id, assertion, actual, expected, passed)
WITH
f AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.fct_response`),
a AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_archetype`),
r AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_run`),
o AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`),
tok AS (SELECT t.option_code, t.option_label FROM f, UNNEST(f.selected_options) AS t),
q AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_question`),
m AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.v_response_metrics`),
fo AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.fct_response_option`),
sc AS (SELECT DISTINCT question_key, scale_max FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`),
qb AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_qre_base`),
checks AS (
  SELECT dq_id, assertion, actual, expected
  FROM UNNEST([
    STRUCT('DQ01' AS dq_id, 'fct_response row count'                        AS assertion, (SELECT COUNT(*) FROM f)                                             AS actual, 40178 AS expected),
    STRUCT('DQ02', 'distinct personas',                                     (SELECT COUNT(DISTINCT archetype_id) FROM f),                                                 398),
    STRUCT('DQ03', 'distinct question_key',                                 (SELECT COUNT(DISTINCT question_key) FROM f),                                                  91),
    STRUCT('DQ04a', 'personas in cohort G.1',                               (SELECT COUNTIF(cohort_code = 'G.1') FROM a),                                                 100),
    STRUCT('DQ04b', 'personas in cohort G.2',                               (SELECT COUNTIF(cohort_code = 'G.2') FROM a),                                                 100),
    STRUCT('DQ04c', 'personas in cohort S.1',                               (SELECT COUNTIF(cohort_code = 'S.1') FROM a),                                                  98),
    STRUCT('DQ04d', 'personas in cohort S.2',                               (SELECT COUNTIF(cohort_code = 'S.2') FROM a),                                                 100),
    STRUCT('DQ05', 'orphan facts (no matching dim_archetype)',              (SELECT COUNTIF(creative IS NULL OR cohort_code IS NULL) FROM f),                               0),
    STRUCT('DQ06', 'personas with NULL age_band_banner',                    (SELECT COUNTIF(age_band_banner IS NULL) FROM a),                                               0),
    STRUCT('DQ07a', 'imputed-age PERSONAS (dim grain) [F2]',                (SELECT COUNTIF(age_band_is_imputed) FROM a),                                                   22),
    STRUCT('DQ07b', 'imputed-age ROWS (fct grain) [F2]',                    (SELECT COUNT(*) FROM f JOIN a USING (archetype_id) WHERE a.age_band_is_imputed),            2302),
    STRUCT('DQ08', 'type-1 rows missing qual_text [F3]',                    (SELECT COUNTIF(q_type = '1' AND qual_text IS NULL) FROM f),                                     3),
    STRUCT('DQ09', 'type-4/5 rows with zero selected_options',              (SELECT COUNTIF(q_type IN ('4','5') AND ARRAY_LENGTH(selected_options) = 0) FROM f),             0),
    STRUCT('DQ10', 'option_label still carrying a leading code [D2]',       (SELECT COUNTIF(REGEXP_CONTAINS(option_label, r'^[0-9]+\.')) FROM tok),                          0),
    STRUCT('DQ11', 'closed questions with scale_max outside [2,12]',        (SELECT COUNT(DISTINCT question_key) FROM o WHERE scale_max NOT BETWEEN 2 AND 12),               6),
    STRUCT('DQ12', 'verbatim count',                                        (SELECT COUNTIF(qual_text IS NOT NULL) FROM f),                                              17301),
    STRUCT('DQ13', 'keys without exactly one is_primary_run',               (SELECT COUNT(*) FROM (
                                                                              SELECT archetype_id, question_key FROM f WHERE is_primary_run
                                                                              GROUP BY 1, 2 HAVING COUNT(*) != 1)),                                                        0),
    STRUCT('DQ14', 'personas with income_high < income_low',                (SELECT COUNTIF(income_high_usd < income_low_usd) FROM a),                                       0),
    STRUCT('DQ15a', 'replicated (persona, question) keys',                  (SELECT COUNT(*) FROM (
                                                                              SELECT archetype_id, question_key FROM f
                                                                              GROUP BY 1, 2 HAVING COUNT(*) = 2)),                                                      3960),
    STRUCT('DQ15b', 'rows belonging to a replicated key',                   (SELECT COUNTIF(n_runs_for_question = 2) FROM f),                                             7920),
    STRUCT('DQ16a', 'dim_run row count',                                    (SELECT COUNT(*) FROM r),                                                                       12),
    STRUCT('DQ16b', 'dim_run sum of n_rows',                                (SELECT CAST(SUM(n_rows) AS INT64) FROM r),                                                   1392),
    STRUCT('DQ17', 'sentinel option tokens (code >= 90) [F5 guard]',        (SELECT COUNTIF(option_code >= 90) FROM tok),                                                  419),
    STRUCT('DQ18', 'sentinel leaked into primary_code [F5 guard]',          (SELECT COUNTIF(primary_code >= 90) FROM f),                                                     0),
    STRUCT('DQ19', 'personas with NULL income_low_usd [F6 guard]',          (SELECT COUNTIF(income_low_usd IS NULL) FROM a),                                                 0),
    -- Step 14: the metric model. DQ20-DQ24 guard the close-out fix.
    STRUCT('DQ20a', 'questions classified ordinal_scale',                   (SELECT COUNTIF(metric_kind = 'ordinal_scale') FROM q),                                         69),
    STRUCT('DQ20b', 'questions classified multi_select',                    (SELECT COUNTIF(metric_kind = 'multi_select') FROM q),                                           9),
    STRUCT('DQ20c', 'questions classified single_option',                   (SELECT COUNTIF(metric_kind = 'single_option') FROM q),                                          2),
    STRUCT('DQ20d', 'questions with NULL metric_kind',                      (SELECT COUNTIF(metric_kind IS NULL) FROM q),                                                    0),
    STRUCT('DQ21', 'fct_response_option row count',                         (SELECT COUNT(*) FROM fo),                                                                  39490),
    STRUCT('DQ22', 'box flags present on a non-ordinal question',           (SELECT COUNTIF(metric_kind != 'ordinal_scale' AND is_tb IS NOT NULL) FROM m),                   0),
    STRUCT('DQ23', 'sentinel rows in fct_response_option [F5 guard]',       (SELECT COUNTIF(is_sentinel) FROM fo),                                                         419),
    STRUCT('DQ24', 'ordinal question with scale_max outside {2,3,4,6}',     (SELECT COUNT(*) FROM q JOIN sc USING (question_key)
                                                                             WHERE q.metric_kind = 'ordinal_scale'
                                                                               AND sc.scale_max NOT IN (2, 3, 4, 6)),                                                       0),
    -- F8: battery-level scale_max
    STRUCT('DQ25', 'questions with battery-corrected scale_max [F8]',       (SELECT COUNT(DISTINCT question_key) FROM o WHERE scale_max_source = 'battery'),                 8),
    STRUCT('DQ26', 'scale_max below the observed max [F8 guard]',           (SELECT COUNT(*) FROM o WHERE scale_max < observed_max),                                         0),
    -- F9 / F11: the questionnaire's own rules, reapplied
    STRUCT('DQ27a', 'ELEMENT1 questions not classified categorical [F9]',   (SELECT COUNTIF(meta = 'ELEMENT1' AND metric_kind != 'categorical') FROM q),                     0),
    STRUCT('DQ27b', 'questions classified categorical [F9]',                (SELECT COUNTIF(metric_kind = 'categorical') FROM q),                                           15),
    STRUCT('DQ28a', 'rows outside the QRE base [F11]',                      (SELECT COUNTIF(NOT is_in_qre_base) FROM f),                                                   676),
    STRUCT('DQ28b', 'rows inside the QRE base [F11]',                       (SELECT COUNTIF(is_in_qre_base) FROM f),                                                     39502),
    STRUCT('DQ28c', 'is_in_qre_base NULL',                                  (SELECT COUNTIF(is_in_qre_base IS NULL) FROM f),                                                0),
    STRUCT('DQ28d', 'ungated question excluded from base [F11 guard]',      (SELECT COUNTIF(NOT is_in_qre_base AND meta NOT IN (SELECT meta FROM qb)) FROM f),               0),
    STRUCT('DQ28e', 'rule table disagrees with implementation [F11 guard]', (SELECT COUNT(*) FROM qb JOIN (
                                                                              SELECT meta, COUNTIF(NOT is_in_qre_base) AS excl FROM f GROUP BY meta
                                                                            ) AS x USING (meta) WHERE x.excl != qb.expected_excluded_rows),                                 0),
    STRUCT('DQ29', 'fct_response row count unchanged by the base flag',     (SELECT COUNT(*) FROM f),                                                                   40178)
  ])
)
SELECT
  CURRENT_TIMESTAMP() AS run_ts,
  dq_id,
  assertion,
  actual,
  expected,
  (actual = expected) AS passed
FROM checks;
