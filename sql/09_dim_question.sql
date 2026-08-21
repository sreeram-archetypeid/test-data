-- 91 rows: the stable question identity is (meta, question_text).
-- Verified 1:1 with q_type (91 pairs, 91 triples), so question_key is unique
-- and the fct_response join cannot fan out.
CREATE OR REPLACE TABLE `ff_20_curated.dim_question` AS
WITH sel AS (
  SELECT meta, question_text, MAX(ARRAY_LENGTH(selected_options)) AS max_selected
  FROM `ff_10_staging.stg_response`
  GROUP BY meta, question_text
),
distinct_q AS (
  SELECT DISTINCT meta, question_text, q_type FROM `ff_10_staging.stg_response`
)
SELECT
  TO_HEX(MD5(CONCAT(t.meta, '||', t.question_text))) AS question_key,
  t.meta, t.question_text, t.q_type,
  -- More than one option ever picked => multi-select. Box metrics are
  -- meaningless there (primary_code = MIN(code) is arbitrary), so
  -- v_response_metrics suppresses them rather than emitting a wrong boolean.
  (sel.max_selected > 1) AS is_multi_select,
  CASE t.q_type WHEN '1' THEN 'open_end'
                WHEN '2' THEN 'numeric_rating'
                WHEN '4' THEN 'closed_select'
                WHEN '5' THEN 'select_plus_verbatim' END AS question_kind
FROM distinct_q t
JOIN sel USING (meta, question_text);

-- Observed option universe per question, plus scale_max.
-- NOTE: this is built from options respondents ACTUALLY SELECTED, so it is an
-- observed universe, not the designed one. Observed codes have gaps (RECONFIRM
-- shows 1,5,6). Top-box anchors on code 1 and is unaffected; bottom-box is
-- provisional until the questionnaire is parsed for the designed option lists.
CREATE OR REPLACE TABLE `ff_20_curated.dim_question_option` AS
WITH opts AS (
  SELECT DISTINCT r.question_key, o.option_code, o.option_label
  FROM `ff_10_staging.stg_response` r, UNNEST(r.selected_options) o
  WHERE o.option_code IS NOT NULL
)
SELECT
  question_key, option_code, option_label,
  option_code >= 90 AS is_sentinel,
  MAX(IF(option_code >= 90, NULL, option_code))
    OVER (PARTITION BY question_key) AS scale_max
FROM opts;
