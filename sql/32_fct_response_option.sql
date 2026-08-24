-- fct_response_option: one row per SELECTED OPTION. Expected 39,490 rows.
--
-- The plan doc names this table in its section 4.1 architecture as part of "the
-- analysis contract" and then never defines it. This is that definition.
--
-- Why it has to exist: for the 9 multi_select questions, fct_response.primary_code
-- keeps only the lowest-numbered pick and discards the rest. Asking "what share
-- of people said Terry Bogard is 'determined'" is unanswerable at the
-- fct_response grain -- the answer lives one level down, here.
--
-- Grain: (archetype_id, run_id, question_key, option_code). Verified against
-- source that each (question_key, option_code) carries exactly one label and one
-- display position, so option_label is stable per option.
--
-- is_primary_run carries through, because incidence over the replicated section
-- 2.1 questions double-counts 198 personas without it, exactly as at the parent
-- grain.
--
-- Clustered by meta, creative: incidence queries filter question first, then
-- creative. Not partitioned -- 39,490 rows is far below where that pays.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.fct_response_option`
CLUSTER BY meta, creative AS
SELECT
  f.archetype_id,
  f.run_id,
  f.section_code,
  f.question_key,
  f.meta,
  f.q_type,
  f.modality,
  f.creative,
  f.cohort_code,
  f.is_primary_run,
  f.n_runs_for_question,
  o.option_position,
  o.option_code,
  o.option_label,
  o.option_code >= 90 AS is_sentinel
FROM `${PROJECT_ID}.${DS_CUR}.fct_response` AS f,
     UNNEST(f.selected_options) AS o;
