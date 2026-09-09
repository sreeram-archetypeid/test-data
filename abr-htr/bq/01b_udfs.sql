-- ============================================================================
-- Stage 1b: the small functions every later stage depends on.
-- ============================================================================
-- Persistent SQL UDFs, so the rules live in one place. If you change one of
-- these you change every number downstream, so change it in git or not at all.
-- ============================================================================

-- Grouping key. NFKC-ish normalisation: straight quotes, single spaces, no
-- trailing punctuation, lowercase. Use for joins and keys ONLY -- never write it
-- back over a source value. Option labels in this study differ by punctuation
-- alone and that drift is itself evidence.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_norm_text`(s STRING)
RETURNS STRING AS (
  REGEXP_REPLACE(
    TRIM(REGEXP_REPLACE(
      LOWER(TRANSLATE(IFNULL(s, ''), '’‘“”–—―', '\'\'""---')),
      r'\s+', ' ')),
    r'[\s.!?,;:]+$', '')
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_slug`(s STRING)
RETURNS STRING AS (
  SUBSTR(REGEXP_REPLACE(
    REGEXP_REPLACE(LOWER(IFNULL(s, '')), r'[^a-z0-9]+', '_'), r'^_+|_+$', ''), 1, 24)
);

-- Question identity. Deliberately EXCLUDES build, date and run, so the same
-- question in two builds carries the same key and the two can be compared.
-- Q{n} position is NOT identity: Q1 in one file is a different question from Q1
-- in another.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_question_key`(
  panel STRING, meta STRING, question_text STRING)
RETURNS STRING AS (
  FORMAT('%s_%s_%s',
    LOWER(IFNULL(panel, 'x')),
    `PROJECT_ID.abr_00_config.fn_slug`(meta),
    SUBSTR(TO_HEX(SHA256(FORMAT('%s|%s|%s',
      LOWER(IFNULL(panel, '')),
      `PROJECT_ID.abr_00_config.fn_norm_text`(meta),
      `PROJECT_ID.abr_00_config.fn_norm_text`(question_text)))), 1, 10))
);

-- Option parsing. '2. 4 - To a great extent' carries TWO numbers:
--   option_code   = 2  the export's code. Its direction is NOT reliable.
--   printed_point = 4  the questionnaire's own scale point. This one is.
-- '1. 1. Increases my interest' is a doubled code prefix, not a printed point.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_option_code`(raw STRING)
RETURNS INT64 AS (
  SAFE_CAST(REGEXP_EXTRACT(IFNULL(raw, ''), r'^\s*([0-9]+)\s*\.') AS INT64)
);

-- everything after the code prefix (and after a doubled code prefix)
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_option_rest`(raw STRING)
RETURNS STRING AS (
  TRIM(REGEXP_REPLACE(IFNULL(raw, ''), r'^\s*[0-9]+\s*\.\s*([0-9]+\s*\.\s*)?', ''))
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_option_printed`(raw STRING)
RETURNS INT64 AS (
  SAFE_CAST(REGEXP_EXTRACT(
    `PROJECT_ID.abr_00_config.fn_option_rest`(raw),
    r'^\s*([0-9]+)\s*[-‐-―:)]\s') AS INT64)
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_option_label`(raw STRING)
RETURNS STRING AS (
  TRIM(REGEXP_REPLACE(
    `PROJECT_ID.abr_00_config.fn_option_rest`(raw),
    r'^\s*[0-9]+\s*[-‐-―:)]\s+', ''))
);

-- Verbatim hygiene. 80-95% of open ends in this study carry roleplay stage
-- directions; left in, they dominate any vector space and every cluster becomes
-- a cluster of gestures. The COUNT is kept separately -- embodiment is a signal.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_strip_stage`(s STRING)
RETURNS STRING AS (
  TRIM(REGEXP_REPLACE(
    REGEXP_REPLACE(IFNULL(s, ''), r'\[[^\[\]]{2,80}\]|\*[^*\n]{2,80}\*', ' '),
    r'\s+', ' '))
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_n_stage`(s STRING)
RETURNS INT64 AS (
  ARRAY_LENGTH(REGEXP_EXTRACT_ALL(IFNULL(s, ''), r'\[[^\[\]]{2,80}\]|\*[^*\n]{2,80}\*'))
);

-- Wilson score interval. Normal-approximation intervals are wrong at n=25 and
-- wrong again near a 95% ceiling, and this study has headline numbers at both.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_wilson_low`(k INT64, n INT64)
RETURNS FLOAT64 AS (
  IF(n = 0 OR n IS NULL, NULL,
    GREATEST(0.0,
      ((k / n) + 1.96 * 1.96 / (2 * n)
       - 1.96 * SQRT((k / n) * (1 - k / n) / n + 1.96 * 1.96 / (4 * n * n)))
      / (1 + 1.96 * 1.96 / n)))
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_wilson_high`(k INT64, n INT64)
RETURNS FLOAT64 AS (
  IF(n = 0 OR n IS NULL, NULL,
    LEAST(1.0,
      ((k / n) + 1.96 * 1.96 / (2 * n)
       + 1.96 * SQRT((k / n) * (1 - k / n) / n + 1.96 * 1.96 / (4 * n * n)))
      / (1 + 1.96 * 1.96 / n)))
);

-- Age arrives as a bare age ('9'), prose ('9 years old'), a clean bucket
-- ('25-34') or a bucket that straddles two banner bands ('18-27'). A straddle is
-- midpointed and FLAGGED, never silently assigned.
CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_age_exact`(raw STRING)
RETURNS INT64 AS (
  SAFE_CAST(REGEXP_EXTRACT(
    `PROJECT_ID.abr_00_config.fn_norm_text`(raw),
    r'^([0-9]{1,3})(?:\s*years?\s*old)?$') AS INT64)
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_age_band`(age INT64)
RETURNS STRING AS (
  CASE
    WHEN age IS NULL THEN NULL
    WHEN age BETWEEN 4 AND 6 THEN '4-6'
    WHEN age BETWEEN 7 AND 9 THEN '7-9'
    WHEN age BETWEEN 10 AND 12 THEN '10-12'
    WHEN age BETWEEN 13 AND 17 THEN '13-17'
    WHEN age BETWEEN 18 AND 24 THEN '18-24'
    WHEN age BETWEEN 25 AND 34 THEN '25-34'
    WHEN age BETWEEN 35 AND 44 THEN '35-44'
    WHEN age BETWEEN 45 AND 54 THEN '45-54'
    WHEN age BETWEEN 55 AND 64 THEN '55-64'
    WHEN age >= 65 THEN '65+'
  END
);

CREATE OR REPLACE FUNCTION `PROJECT_ID.abr_00_config.fn_gender_norm`(raw STRING)
RETURNS STRING AS (
  CASE
    WHEN STARTS_WITH(`PROJECT_ID.abr_00_config.fn_norm_text`(raw), 'm') THEN 'Male'
    WHEN STARTS_WITH(`PROJECT_ID.abr_00_config.fn_norm_text`(raw), 'f') THEN 'Female'
  END
);
