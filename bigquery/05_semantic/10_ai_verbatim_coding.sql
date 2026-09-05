-- ============================================================================
-- STAGE 5c — VERBATIM CODING
--
-- WHAT: AI.GENERATE_TABLE over the ~1,019 clean open-ends, forcing a fixed
-- codeframe so qual becomes something a banner can hold.
--
-- WHY the codeframe includes mentions_sensory_overload: the strongest negative
-- in the study (40-44% volunteered it) has NO closed-end option anywhere — of
-- 104 options the only one touching sound is "The music", listed as a LIKED
-- element. This flag is the variable the instrument never had. It is the main
-- reason to run this stage at all.
--
-- RUN THE SAMPLE FIRST. The LIMIT 20 block below costs pennies; read its output
-- before the full pass. A wrong prompt here does not error — it silently
-- mis-codes 1,019 rows.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

-- ---- 5c.1  The corpus: what goes in, and what is deliberately excluded -----
CREATE OR REPLACE VIEW `PROJECT_ID.abr_20_curated.v_verbatim_corpus` AS
SELECT
  f.archetype_id, f.instrument, f.question_key, f.question_text,
  f.qual_clean, f.qual_raw, f.is_fatigued, f.question_num,
  a.age, a.gender, a.ethnicity, a.age_band
FROM `PROJECT_ID.abr_20_curated.fct_response` f
JOIN `PROJECT_ID.abr_20_curated.dim_archetype` a USING (archetype_id)
WHERE f.question_type = 'open_end'
  AND f.qual_clean IS NOT NULL AND LENGTH(f.qual_clean) > 0
  AND NOT f.is_instruction   -- Q3 is an instruction screen, not a question
  AND NOT f.is_leaked        -- the 2 orchestration-JSON cells
  AND f.question_key != 'Q50';  -- factual recall ("what was the movie called"),
                                -- scored against ground truth in Stage 9, not
                                -- coded for sentiment. It is also the most
                                -- fatigue-contaminated item (45% markers).

-- ---- 5c.2  SAMPLE FIRST. Read this output before running 5c.3. -------------
SELECT archetype_id, question_key, qual_clean,
       sentiment, primary_theme, mentions_sensory_overload, intensity
FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_30_semantic.gemini_text`,
  (SELECT archetype_id, question_key, qual_clean,
          CONCAT(
            'Code this open-end response from a children''s movie-trailer test.\n',
            'Respondent age: ', CAST(age AS STRING), '.\n',
            'Question: ', question_text, '\n',
            'Response: ', qual_clean, '\n\n',
            'CODING RULES:\n',
            'sentiment: Positive | Neutral | Negative | Mixed — toward the TRAILER, ',
            'not toward the survey. A child complaining about being tired of ',
            'questions is not negative about the trailer.\n',
            'primary_theme / secondary_theme, choose from: Dog or animal appeal | ',
            'Sport or basketball | Comedy or humour | Underdog or winning | ',
            'Friendship or teamwork | Family or co-viewing | Sensory or audio | ',
            'Scary or mean characters | Boring or pacing | Predictable or derivative | ',
            'Realism or CGI | Intent to view | No opinion or fatigue | Other\n',
            'mentions_sensory_overload: true if the response objects to loudness, ',
            'yelling, shouting, the buzzer, the music mix, or noise generally. ',
            'This is the study''s key uncoded variable — be precise, not generous.\n',
            'intensity: 1 (passing mention) to 5 (strong, repeated, emphatic).\n',
            'is_actionable_note: true only if it names something a filmmaker could ',
            'actually change.'
          ) AS prompt
   FROM `PROJECT_ID.abr_20_curated.v_verbatim_corpus`
   WHERE question_key = 'Q32'   -- dislikes: the densest question for this flag
   LIMIT 20),
  STRUCT(
    'sentiment STRING, primary_theme STRING, secondary_theme STRING, '
    'mentions_sensory_overload BOOL, mentions_dog BOOL, mentions_sport BOOL, '
    'intensity INT64, is_actionable_note BOOL' AS output_schema,
    0.0 AS temperature)
);

-- ---- 5c.3  FULL PASS — only after the sample looks right --------------------
-- Identical prompt. If you edit the prompt, register the new version in
-- abr_90_ops.prompt_registry first: a silent edit re-codes the whole study.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.verbatim_coded` AS
SELECT *, 'verbatim_code_v1' AS prompt_id, CURRENT_TIMESTAMP() AS coded_at
FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_30_semantic.gemini_text`,
  (SELECT archetype_id, instrument, question_key, age, gender, ethnicity,
          age_band, is_fatigued, qual_clean,
          CONCAT(
            'Code this open-end response from a children''s movie-trailer test.\n',
            'Respondent age: ', CAST(age AS STRING), '.\n',
            'Question: ', question_text, '\n',
            'Response: ', qual_clean, '\n\n',
            'CODING RULES:\n',
            'sentiment: Positive | Neutral | Negative | Mixed — toward the TRAILER, ',
            'not toward the survey. A child complaining about being tired of ',
            'questions is not negative about the trailer.\n',
            'primary_theme / secondary_theme, choose from: Dog or animal appeal | ',
            'Sport or basketball | Comedy or humour | Underdog or winning | ',
            'Friendship or teamwork | Family or co-viewing | Sensory or audio | ',
            'Scary or mean characters | Boring or pacing | Predictable or derivative | ',
            'Realism or CGI | Intent to view | No opinion or fatigue | Other\n',
            'mentions_sensory_overload: true if the response objects to loudness, ',
            'yelling, shouting, the buzzer, the music mix, or noise generally. ',
            'This is the study''s key uncoded variable — be precise, not generous.\n',
            'intensity: 1 (passing mention) to 5 (strong, repeated, emphatic).\n',
            'is_actionable_note: true only if it names something a filmmaker could ',
            'actually change.'
          ) AS prompt
   FROM `PROJECT_ID.abr_20_curated.v_verbatim_corpus`),
  STRUCT(
    'sentiment STRING, primary_theme STRING, secondary_theme STRING, '
    'mentions_sensory_overload BOOL, mentions_dog BOOL, mentions_sport BOOL, '
    'intensity INT64, is_actionable_note BOOL' AS output_schema,
    0.0 AS temperature)
);

-- ---- 5c.4  The human-validation sample -------------------------------------
-- WHY: an LLM coding LLM-generated verbatims shares failure modes with the
-- generator — pleasantness bias especially, which would inflate an already very
-- positive result. Export these 100 rows, have an analyst code them blind, load
-- the result to abr_90_ops.human_codes, and compute Cohen's kappa. Below ~0.7,
-- fix the codeframe rather than shipping the numbers.
--
-- Stratified so negatives are represented: Q32/Q28 carry the complaints.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_90_ops.human_coding_sample` AS
SELECT archetype_id, instrument, question_key, question_text, qual_clean,
       CAST(NULL AS STRING) AS human_sentiment,
       CAST(NULL AS STRING) AS human_primary_theme,
       CAST(NULL AS BOOL)   AS human_sensory_flag
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY question_key ORDER BY FARM_FINGERPRINT(archetype_id)) AS rn
  FROM `PROJECT_ID.abr_20_curated.v_verbatim_corpus`
)
WHERE rn <= 15
LIMIT 100;
