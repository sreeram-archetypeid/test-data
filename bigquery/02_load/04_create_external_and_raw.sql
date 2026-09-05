-- ============================================================================
-- STAGE 2b — external tables, then raw load
--
-- WHY external tables first: an external table reads the CSV in place, so you
-- can inspect the header and row count before committing a load. It costs
-- nothing and catches a malformed file before it becomes a table.
--
-- WHY every column STRING: this is the single most important decision in the
-- load. BigQuery autodetect will happily type Q12_rating as INT64 (it is 100%
-- empty, so it guesses), and will type age_range as INT64 while the source has
-- it as text. Worse, autodetect on these files can mis-handle the 6,306-char
-- leaked-JSON cell. Load everything as STRING; cast in the curated layer where
-- the cast is visible, reviewable and reversible.
--
-- WHY allow_quoted_newlines: verbatims contain embedded newlines inside quoted
-- fields. Without this flag the CSV shreds into garbage rows and the row count
-- comes out in the hundreds instead of 43/109. This is not optional.
--
-- Replace PROJECT_ID and STAMP (from Stage 2a) throughout.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 2b.1  External tables — inspect before loading
-- ---------------------------------------------------------------------------
CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.abr_00_ext.ext_t1`
OPTIONS (
  format = 'CSV',
  uris = ['gs://PROJECT_ID-abr-tsr-landing/raw/STAMP/abr_tsr_v4_k_t1.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = TRUE,
  allow_jagged_rows = FALSE,      -- a jagged row here means a real parse problem
  ignore_unknown_values = FALSE   -- fail loudly rather than dropping data
);

CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.abr_00_ext.ext_t23`
OPTIONS (
  format = 'CSV',
  uris = ['gs://PROJECT_ID-abr-tsr-landing/raw/STAMP/abr_tsr_v4_k_t23.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = TRUE,
  allow_jagged_rows = FALSE,
  ignore_unknown_values = FALSE
);

-- GATE: these must return exactly 43 and 109. Any other number means
-- allow_quoted_newlines did not take effect, or you have a different export.
-- Do not proceed past this query until both are right.
SELECT 'ext_t1' AS tbl, COUNT(*) AS n, 43 AS expected FROM `PROJECT_ID.abr_00_ext.ext_t1`
UNION ALL
SELECT 'ext_t23', COUNT(*), 109 FROM `PROJECT_ID.abr_00_ext.ext_t23`;


-- ---------------------------------------------------------------------------
-- 2b.2  Materialise into the raw layer
--
-- WHY materialise at all, when external tables work: external tables re-read
-- GCS on every query, so a file moved or overwritten silently changes your
-- results. The raw layer is the immutable snapshot the whole analysis is
-- reproducible against. It also lets you drop the GCS objects later without
-- breaking anything.
--
-- WHY the extra provenance columns: once the two files are unpivoted into one
-- long fact table, "which instrument did this row come from" becomes the most
-- important column in the warehouse — it is what stops the scale-mismatch bug
-- (README, N1) from silently reappearing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_10_raw.raw_t1` AS
SELECT
  'T1'                       AS instrument,   -- 2-3 point scales, ages 4-7
  'ages_4_7'                 AS age_band,
  'abr_tsr_v4_k_t1.csv'      AS source_file,
  CURRENT_TIMESTAMP()        AS loaded_at,
  *
FROM `PROJECT_ID.abr_00_ext.ext_t1`;

CREATE OR REPLACE TABLE `PROJECT_ID.abr_10_raw.raw_t23` AS
SELECT
  'T23'                      AS instrument,   -- 5 point scales, ages 8-12
  'ages_8_12'                AS age_band,
  'abr_tsr_v4_k_t23.csv'     AS source_file,
  CURRENT_TIMESTAMP()        AS loaded_at,
  *
FROM `PROJECT_ID.abr_00_ext.ext_t23`;


-- ---------------------------------------------------------------------------
-- 2b.3  Column inventory
--
-- WHY: T1 has 312 columns and T23 has 333, because they ask different
-- questions. Stage 4's unpivot is generated from this inventory rather than
-- hand-written, so it adapts to whichever question set each file carries. This
-- table is that generator's input.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_90_ops.column_inventory` AS
WITH cols AS (
  SELECT 'T1' AS instrument, column_name, ordinal_position
  FROM `PROJECT_ID.abr_10_raw.INFORMATION_SCHEMA.COLUMNS`
  WHERE table_name = 'raw_t1'
  UNION ALL
  SELECT 'T23', column_name, ordinal_position
  FROM `PROJECT_ID.abr_10_raw.INFORMATION_SCHEMA.COLUMNS`
  WHERE table_name = 'raw_t23'
)
SELECT
  instrument,
  column_name,
  ordinal_position,
  -- Question columns look like Q<number>_<field>. Everything else is either
  -- persona metadata (archetype_*) or the provenance columns added above.
  REGEXP_EXTRACT(column_name, r'^Q(\d+)_')          AS question_num,
  REGEXP_EXTRACT(column_name, r'^Q\d+_(.+)$')       AS question_field,
  CASE
    WHEN REGEXP_CONTAINS(column_name, r'^Q\d+_')    THEN 'question'
    WHEN STARTS_WITH(column_name, 'archetype_')     THEN 'persona'
    ELSE 'provenance'
  END                                               AS column_class
FROM cols;

-- Sanity read: expect T1 = 38 questions x 7 fields = 266 question columns,
-- T23 = 41 x 7 = 287, plus 44 persona columns and 4 provenance each.
SELECT instrument, column_class, COUNT(*) AS cols,
       COUNT(DISTINCT question_num) AS distinct_questions
FROM `PROJECT_ID.abr_90_ops.column_inventory`
GROUP BY 1,2 ORDER BY 1,2;
