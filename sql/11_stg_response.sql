-- Union the three section families and parse/type everything.
--
-- This is where the data-quality rules from the plan doc are applied. Each one
-- encodes a defect measured in the source, not a hypothetical.
--
--   D2/F5  the numeric prefix on a selected option is `position. code.`, NOT a
--          duplicated code. They coincide 38,275 times out of 39,490, which is
--          why the doc treats them as duplicates -- but they differ in 419
--          cases and in every one of those the second number is 99
--          ("None of the above"), the D9 sentinel. Reading the FIRST number
--          would code the sentinel as 9 / 6 / 17 and inflate scale_max on
--          Screener 1 (9 vs 8), PLATFORM (6 vs 5) and SOCIAL (17 vs 15),
--          silently corrupting BOT / B2B / MEAN on those three questions.
--          So: option_code is the LAST prefix, option_position the first.
--
--   D3     multi-selects are pipe-delimited in one string. Verified that no
--          option label contains a pipe, so SPLIT is safe.
--
--   D7     curly apostrophes (U+2019) appear in verbatims. qual_text keeps the
--          raw bytes; qual_text_norm is a normalised copy for grouping only.
--
--   D11    archetype_nps_score and the rating column are strings in source.
--          SAFE_CAST here, never in raw.
--
-- q_idx is positional within a file and NOT a stable id. question_key =
-- MD5(meta || '||' || question_text) is the stable identity; verified to
-- produce 91 distinct keys with zero collisions across differing q_type.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_STG}.stg_response` AS
WITH all_sections AS (
  SELECT '2.1' AS section_code, * FROM `${PROJECT_ID}.${DS_STG}.stg_response_s21`
  UNION ALL
  SELECT '2.2' AS section_code, * FROM `${PROJECT_ID}.${DS_STG}.stg_response_s22`
  UNION ALL
  SELECT '2.3' AS section_code, * FROM `${PROJECT_ID}.${DS_STG}.stg_response_s23`
)
SELECT
  archetype_id,
  run_id,
  section_code,
  q_idx,
  meta,
  question_text,
  q_type,
  TO_HEX(MD5(CONCAT(meta, '||', question_text)))        AS question_key,

  NULLIF(TRIM(rating_label), '')                        AS rating_label,
  SAFE_CAST(NULLIF(TRIM(rating), '') AS INT64)          AS rating_value,

  NULLIF(selected, '')                                  AS selected_raw,

  -- D3 + D2/F5
  ARRAY(
    SELECT AS STRUCT
      -- first prefix: position in the displayed option list
      SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64)      AS option_position,
      -- last prefix: the authoritative coded value (99 = None of the above)
      SAFE_CAST(
        COALESCE(
          REGEXP_EXTRACT(opt, r'^\s*\d+\.\s*(\d+)\.'),
          REGEXP_EXTRACT(opt, r'^\s*(\d+)\.')
        ) AS INT64
      )                                                            AS option_code,
      TRIM(REGEXP_REPLACE(opt, r'^\s*\d+\.\s*(\d+\.\s*)?', ''))    AS option_label
    FROM UNNEST(SPLIT(COALESCE(selected, ''), '|')) AS opt
    WHERE TRIM(opt) != ''
  )                                                     AS selected_options,

  NULLIF(qual, '')                                      AS qual_text,
  CHAR_LENGTH(COALESCE(qual, ''))                       AS qual_len,
  -- D7: normalised for grouping only; qual_text stays verbatim
  NULLIF(
    REPLACE(REPLACE(REPLACE(REPLACE(qual, '’', "'"), '‘', "'"), '“', '"'), '”', '"'),
    ''
  )                                                     AS qual_text_norm

FROM all_sections
WHERE question_text IS NOT NULL
  AND TRIM(question_text) != '';
