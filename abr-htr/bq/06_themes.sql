-- ============================================================================
-- Stage 6: semantics and themes over the verbatims and the aat prose.
-- ============================================================================
-- Three passes, in this order, because each one checks the one before it:
--   a. hygiene   -- strip roleplay stage directions, quarantine harness JSON,
--                   drop instruction screens, flag null responses
--   b. codeframe -- deterministic, multi-label, every hit records the pattern
--   c. gaps      -- see 11_ai_embeddings.sql for the no-codeframe clustering that
--                   tells you what this frame is missing
--
-- Incidence is per PERSONA and scoped to a question ROLE. "Does this persona
-- mention the dog anywhere across 20 open ends" is ~100% for every theme worth
-- having and tells you nothing; "of those asked what they did not like, what
-- share raised the audio" is a number you can act on.
-- ============================================================================

-- Not data: an instruction screen that carries 'responses' because the harness
-- answered it anyway.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.v_verbatim` AS
SELECT
  FORMAT('%s:%s:%d', f.run_id, f.archetype_id, f.q_position) AS doc_id,
  f.run_id, f.panel, f.build, f.archetype_id, f.question_key, f.q_position, f.meta,
  q.question_text, 'verbatim' AS source,
  f.qual_clean, f.n_stage_directions, LENGTH(f.qual_clean) AS n_chars,
  -- "Nothing, I loved the dog!" is a null complaint, not a complaint about the
  -- dog. Without this the dislike read shows the dog at ~45% and means nothing.
  REGEXP_CONTAINS(LOWER(f.qual_clean),
    r"^\s*(nothing|none|no+|nope|not really|nah|i liked (it all|everything)"
    r"|everything was (good|great|fine)|i did ?n[o']?t dislike"
    r"|there was ?n[o']?t anything|no complaints)\b") AS is_null_response
FROM `PROJECT_ID.abr_20_curated.fct_response` f
JOIN `PROJECT_ID.abr_20_curated.dim_question` q USING (run_id, question_key)
WHERE COALESCE(f.qual_clean, '') != ''
  AND NOT f.is_harness_leak
  AND NOT REGEXP_CONTAINS(LOWER(IFNULL(q.question_text, '')),
                          r'^(next, you will watch|please watch|now you will)');

-- The aat_* prose fields, long. Model-written summary text in a house style, so
-- it is coded and reported SEPARATELY -- mixed into the respondent corpus it
-- clusters on that style instead of on what personas said.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.v_aat_prose` AS
SELECT
  FORMAT('%s:%s:%s', a.run_id, a.archetype_id, p.col) AS doc_id,
  a.run_id, a.panel, a.build, a.archetype_id,
  CAST(NULL AS STRING) AS question_key, CAST(NULL AS INT64) AS q_position,
  p.col AS meta, p.col AS question_text, 'aat_prose' AS source,
  `PROJECT_ID.abr_00_config.fn_strip_stage`(p.val) AS qual_clean,
  `PROJECT_ID.abr_00_config.fn_n_stage`(p.val) AS n_stage_directions,
  LENGTH(IFNULL(p.val, '')) AS n_chars,
  FALSE AS is_null_response
FROM `PROJECT_ID.abr_20_curated.dim_aat` a,
UNNEST([
  STRUCT('aat_opening_pact_promise' AS col, a.aat_opening_pact_promise AS val),
  ('aat_outrage_trigger', a.aat_outrage_trigger),
  ('aat_crossover_alienation', a.aat_crossover_alienation),
  ('aat_lifecycle_reaction', a.aat_lifecycle_reaction),
  ('aat_genre_contract', a.aat_genre_contract),
  ('aat_expectation_delta', a.aat_expectation_delta),
  ('aat_confusion_vs_intrigue', a.aat_confusion_vs_intrigue),
  ('aat_event_density_stretch_snap', a.aat_event_density_stretch_snap),
  ('aat_subjective_pacing', a.aat_subjective_pacing),
  ('aat_second_screen', a.aat_second_screen),
  ('aat_parasocial_attachment', a.aat_parasocial_attachment),
  ('aat_peak_end_override', a.aat_peak_end_override),
  ('aat_playability_recommend', a.aat_playability_recommend)
]) AS p
WHERE COALESCE(p.val, '') NOT IN ('', 'Low', 'Med', 'High');

CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.v_corpus` AS
SELECT * FROM `PROJECT_ID.abr_20_curated.v_verbatim`
UNION ALL
SELECT * FROM `PROJECT_ID.abr_20_curated.v_aat_prose`;

-- ---------------------------------------------------------------------------
-- Codeframe coding. Multi-label, and the pattern that fired is kept so any
-- number in the output can be traced back to the sentence that produced it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.verbatim_code`
CLUSTER BY run_id, theme_id AS
SELECT
  c.doc_id, c.run_id, c.panel, c.build, c.archetype_id, c.question_key, c.meta,
  c.source, f.theme_id, f.theme_label, f.theme_polarity,
  ANY_VALUE(f.pattern) AS matched_pattern,
  ANY_VALUE(c.n_chars) AS n_chars,
  ANY_VALUE(SUBSTR(c.qual_clean, 1, 400)) AS text
FROM `PROJECT_ID.abr_20_curated.v_corpus` c
JOIN `PROJECT_ID.abr_00_config.codeframe` f
  ON REGEXP_CONTAINS(LOWER(c.qual_clean), f.pattern)
WHERE NOT c.is_null_response
GROUP BY c.doc_id, c.run_id, c.panel, c.build, c.archetype_id, c.question_key,
         c.meta, c.source, f.theme_id, f.theme_label, f.theme_polarity;

-- Which read does each question support. 'any' is always present; a meta may
-- belong to more than one role.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.v_verbatim_role` AS
SELECT v.doc_id, v.run_id, v.panel, v.archetype_id, v.meta, v.is_null_response, 'any' AS role
FROM `PROJECT_ID.abr_20_curated.v_verbatim` v
UNION ALL
SELECT v.doc_id, v.run_id, v.panel, v.archetype_id, v.meta, v.is_null_response, r.role
FROM `PROJECT_ID.abr_20_curated.v_verbatim` v
JOIN `PROJECT_ID.abr_00_config.question_role` r
  ON v.meta = r.meta OR (ENDS_WITH(r.meta, '_') AND STARTS_WITH(v.meta, r.meta));

-- ---------------------------------------------------------------------------
-- Theme incidence: personas, by role and cut, with Wilson intervals and a base
-- flag. Base is personas who ANSWERED a question in the role -- never all
-- personas: one panel is n=25, and only those who found something scary were
-- meant to reach the scary probe.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.theme_by_cut` AS
WITH base AS (
  SELECT r.role, c.cut, c.cut_value, r.run_id,
         COUNT(DISTINCT r.archetype_id) AS base,
         COUNT(DISTINCT IF(r.is_null_response, r.archetype_id, NULL)) AS null_responders
  FROM `PROJECT_ID.abr_20_curated.v_verbatim_role` r
  JOIN `PROJECT_ID.abr_20_curated.dim_archetype_cut` c
    USING (run_id, archetype_id)
  GROUP BY r.role, c.cut, c.cut_value, r.run_id
),
hits AS (
  SELECT r.role, c.cut, c.cut_value, r.run_id, v.theme_id,
         ANY_VALUE(v.theme_label) AS theme_label,
         ANY_VALUE(v.theme_polarity) AS theme_polarity,
         COUNT(DISTINCT v.archetype_id) AS personas_mentioning
  FROM `PROJECT_ID.abr_30_marts.verbatim_code` v
  JOIN `PROJECT_ID.abr_20_curated.v_verbatim_role` r USING (doc_id)
  JOIN `PROJECT_ID.abr_20_curated.dim_archetype_cut` c
    ON c.run_id = v.run_id AND c.archetype_id = v.archetype_id
  WHERE v.source = 'verbatim'
  GROUP BY r.role, c.cut, c.cut_value, r.run_id, v.theme_id
)
SELECT
  b.run_id, b.role, b.cut, b.cut_value,
  t.theme_id, t.theme_label, t.theme_polarity,
  b.base,
  IFNULL(h.personas_mentioning, 0) AS personas_mentioning,
  ROUND(100.0 * IFNULL(h.personas_mentioning, 0) / b.base, 1) AS pct,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_low`(
    IFNULL(h.personas_mentioning, 0), b.base), 1) AS wilson_low,
  ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_high`(
    IFNULL(h.personas_mentioning, 0), b.base), 1) AS wilson_high,
  ROUND(100.0 * b.null_responders / b.base, 1) AS null_response_pct,
  IF(b.base >= 30, '', 'BASE<30 -- report counts, not %') AS base_flag
FROM base b
CROSS JOIN (SELECT DISTINCT theme_id, theme_label, theme_polarity
            FROM `PROJECT_ID.abr_00_config.codeframe`) t
LEFT JOIN hits h
  ON h.run_id = b.run_id AND h.role = b.role AND h.cut = b.cut
 AND h.cut_value = b.cut_value AND h.theme_id = t.theme_id;

-- Per-question detail, so any role number can be opened up.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.theme_by_question` AS
WITH base AS (
  SELECT run_id, panel, meta, ANY_VALUE(question_text) AS question_text,
         COUNT(DISTINCT archetype_id) AS base
  FROM `PROJECT_ID.abr_20_curated.v_verbatim`
  GROUP BY run_id, panel, meta
)
SELECT b.run_id, b.panel, b.meta, b.question_text, v.theme_id, v.theme_polarity,
       b.base, COUNT(DISTINCT v.archetype_id) AS personas_mentioning,
       ROUND(100.0 * COUNT(DISTINCT v.archetype_id) / b.base, 1) AS pct,
       ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_low`(
         COUNT(DISTINCT v.archetype_id), b.base), 1) AS wilson_low,
       ROUND(100 * `PROJECT_ID.abr_00_config.fn_wilson_high`(
         COUNT(DISTINCT v.archetype_id), b.base), 1) AS wilson_high
FROM base b
JOIN `PROJECT_ID.abr_30_marts.verbatim_code` v
  ON v.run_id = b.run_id AND v.meta = b.meta AND v.source = 'verbatim'
GROUP BY b.run_id, b.panel, b.meta, b.question_text, v.theme_id, v.theme_polarity, b.base;

-- What the codeframe does not touch. This is the input to the next codeframe
-- revision, and it is the honest denominator for "88% of verbatims coded".
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_marts.uncoded_verbatim` AS
SELECT v.doc_id, v.run_id, v.panel, v.meta, v.n_chars, SUBSTR(v.qual_clean, 1, 400) AS text
FROM `PROJECT_ID.abr_20_curated.v_verbatim` v
LEFT JOIN (SELECT DISTINCT doc_id FROM `PROJECT_ID.abr_30_marts.verbatim_code`) c
  USING (doc_id)
WHERE c.doc_id IS NULL AND NOT v.is_null_response AND v.n_chars >= 25
ORDER BY v.n_chars DESC;
