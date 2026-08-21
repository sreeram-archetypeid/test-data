-- Parse and type the long rows. Handles D2 (doubled option prefix),
-- D3 (pipe-packed multi-select), D7 (curly apostrophes), D11 (string NPS).
CREATE OR REPLACE TABLE `ff_10_staging.stg_response` AS
WITH all_sections AS (
  SELECT *, '2.1' AS section_code FROM `ff_10_staging.stg_response_s21`
  UNION ALL SELECT *, '2.2' FROM `ff_10_staging.stg_response_s22`
  UNION ALL SELECT *, '2.3' FROM `ff_10_staging.stg_response_s23`
)
SELECT
  archetype_id, run_id, section_code, q_idx,
  meta, question_text, q_type,
  TO_HEX(MD5(CONCAT(meta, '||', question_text))) AS question_key,
  rating_label,
  SAFE_CAST(NULLIF(TRIM(rating), '') AS INT64) AS rating_value,
  NULLIF(selected, '') AS selected_raw,
  -- D2 + D3: split on '|', strip a single OR doubled leading code
  ARRAY(
    SELECT AS STRUCT
      SAFE_CAST(REGEXP_EXTRACT(opt, r'^\s*(\d+)\.') AS INT64) AS option_code,
      TRIM(REGEXP_REPLACE(opt, r'^\s*\d+\.\s*(\d+\.\s*)?', '')) AS option_label
    FROM UNNEST(SPLIT(COALESCE(selected, ''), '|')) AS opt
    WHERE TRIM(opt) != ''
  ) AS selected_options,
  NULLIF(qual, '') AS qual_text,
  CHAR_LENGTH(COALESCE(qual, '')) AS qual_len,
  -- D7: normalised copy for grouping only; qual_text stays verbatim
  NULLIF(REPLACE(REPLACE(qual, '’', "'"), '“', '"'), '') AS qual_text_norm
FROM all_sections
WHERE question_text IS NOT NULL AND question_text != '';
