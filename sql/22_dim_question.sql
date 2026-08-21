-- dim_question: the stable identity of a question. Expected 91 rows, 36 metas.
--
-- Q{n} numbering is positional within a file, not a question id -- Q1 in
-- section 2.2 is a different question from Q1 in section 2.3. Stable identity
-- is (meta, question_text), hashed to question_key.
--
-- Verified against source: 91 distinct (meta, question_text, q_type) triples,
-- and zero cases where one (meta, question_text) pair carries two different
-- q_type values. So question_key is unique at 91 rows and hashing without
-- q_type is safe.
--
-- q_type semantics, derived from fill patterns and confirmed by row counts:
--   1  open end            4,574 rows, verbatim only
--   2  numeric rating        596 rows, rating only
--   4  closed select      30,830 rows, selection (+ optional probe verbatim)
--   5  select + verbatim   4,178 rows, selection AND mandatory verbatim

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_question` AS
SELECT
  TO_HEX(MD5(CONCAT(meta, '||', question_text))) AS question_key,
  meta,
  question_text,
  q_type,
  CASE q_type
    WHEN '1' THEN 'open_end'
    WHEN '2' THEN 'numeric_rating'
    WHEN '4' THEN 'closed_select'
    WHEN '5' THEN 'select_plus_verbatim'
  END AS question_kind
FROM (
  SELECT DISTINCT meta, question_text, q_type
  FROM `${PROJECT_ID}.${DS_STG}.stg_response`
);
