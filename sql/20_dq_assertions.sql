-- =====================================================================
-- Data-quality gates, manifest-driven  (plan §8, DQ01-DQ16)
--
-- The problem with the plan as written: every threshold is a literal
-- (= 40,178, = 398, = 91, = 3,960). Those are facts about the READ export,
-- not about the pipeline. The day AUDIO lands, all sixteen assertions go
-- red and the only available fix is to edit the numbers -- which silently
-- destroys their value as regression tests.
--
-- Fix: split the gates into two classes.
--
--   CLASS A  derived  -- computed from the load manifest at run time.
--                        Self-updating. New files change the expectation
--                        automatically because the expectation IS the
--                        measured shape of the source.
--   CLASS B  baselined -- content facts that cannot be derived from file
--                        shape (question universe, verbatim count).
--                        Stored in dq_baseline with an explicit owner and
--                        date. Drift is reported, never auto-accepted.
--
-- Class B is deliberately awkward to change: re-baselining is an INSERT
-- with a note, so the git history shows who moved a goalpost and why.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Manifest, loaded from tools/profile_survey_csv.py --ndjson
--   bq load --source_format=NEWLINE_DELIMITED_JSON --autodetect \
--     ff_00_raw.load_manifest build/load_manifest.ndjson
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `ff_00_raw.dq_baseline` (
  metric      STRING  NOT NULL,
  modality    STRING  NOT NULL,
  expected    INT64   NOT NULL,
  set_on      DATE    NOT NULL,
  set_by      STRING,
  note        STRING
);

CREATE TABLE IF NOT EXISTS `ff_30_marts.dq_results` (
  run_ts      TIMESTAMP,
  dq_id       STRING,
  class       STRING,
  modality    STRING,
  assertion   STRING,
  expected    INT64,
  actual      INT64,
  passed      BOOL,
  detail      STRING
);

-- Seed Class B from the measured READ export. Re-run only with a new note.
INSERT INTO `ff_00_raw.dq_baseline`
  (metric, modality, expected, set_on, set_by, note)
SELECT * FROM UNNEST([
  STRUCT('question_universe' AS metric, 'READ' AS modality, 91 AS expected,
         DATE '2026-09-17' AS set_on, 'migration-plan §7.3' AS set_by,
         '20+35+36 sections' AS note),
  STRUCT('verbatim_rows', 'READ', 17301, DATE '2026-09-17',
         'migration-plan §8 DQ12', 'primary-run verbatims'),
  STRUCT('replicate_keys', 'READ', 3960, DATE '2026-09-17',
         'migration-plan §7.3', 'G.2 100x20 + S.1 98x20'),
  STRUCT('imputed_age_rows', 'READ', 81, DATE '2026-09-17',
         'migration-plan §3 D4', '17-24 band, straddles 13-17/18-24')
])
WHERE NOT EXISTS (SELECT 1 FROM `ff_00_raw.dq_baseline` WHERE modality = 'READ');


-- =====================================================================
-- CLASS A -- derived from the manifest. These need no edit, ever.
-- =====================================================================

INSERT INTO `ff_30_marts.dq_results`
WITH m AS (
  SELECT modality,
         SUM(expected_fact_rows) AS exp_facts,
         SUM(n_rows)             AS exp_source_rows,
         COUNT(*)                AS exp_files
  FROM `ff_00_raw.load_manifest`
  GROUP BY modality
),
actual AS (
  SELECT modality,
         COUNT(*)                                   AS fact_rows,
         COUNT(DISTINCT archetype_id)               AS personas,
         COUNT(DISTINCT question_key)               AS questions,
         COUNTIF(is_primary_run)                    AS primary_rows,
         COUNT(DISTINCT FORMAT('%s|%s', archetype_id, question_key)) AS distinct_keys,
         COUNT(DISTINCT run_id)                     AS runs
  FROM `ff_20_curated.fct_response`
  GROUP BY modality
)
SELECT CURRENT_TIMESTAMP(), dq_id, 'A', modality, assertion, expected, actual,
       expected = actual,
       IF(expected = actual, NULL,
          FORMAT('drift %+d', actual - expected))
FROM (
  SELECT 'DQ01' AS dq_id, m.modality,
         'fct_response row count = SUM(manifest.expected_fact_rows)' AS assertion,
         m.exp_facts AS expected, a.fact_rows AS actual
  FROM m JOIN actual a USING (modality)
  UNION ALL
  SELECT 'DQ13', m.modality,
         'exactly one primary run per (persona, question)',
         a.distinct_keys, a.primary_rows
  FROM m JOIN actual a USING (modality)
  UNION ALL
  SELECT 'DQ16', m.modality,
         'dim_run completeness = manifest file count',
         m.exp_files, a.runs
  FROM m JOIN actual a USING (modality)
);

-- DQ05 orphan facts -- structural, no threshold needed.
INSERT INTO `ff_30_marts.dq_results`
SELECT CURRENT_TIMESTAMP(), 'DQ05', 'A', f.modality,
       'no fact rows without a dim_archetype parent', 0, COUNT(*), COUNT(*) = 0,
       FORMAT('%d orphan archetype_id', COUNT(*))
FROM `ff_20_curated.fct_response` f
LEFT JOIN `ff_20_curated.dim_archetype` d USING (archetype_id)
WHERE d.archetype_id IS NULL
GROUP BY f.modality;

-- Per-file reconciliation: catches a single bad load that nets out in totals.
INSERT INTO `ff_30_marts.dq_results`
SELECT CURRENT_TIMESTAMP(), 'DQ01b', 'A', m.modality,
       FORMAT('per-file fact rows: %s', m.slug),
       m.expected_fact_rows, COUNT(f.archetype_id),
       m.expected_fact_rows = COUNT(f.archetype_id), NULL
FROM `ff_00_raw.load_manifest` m
LEFT JOIN `ff_20_curated.fct_response` f ON f.run_id = m.slug
GROUP BY m.modality, m.slug, m.expected_fact_rows;


-- =====================================================================
-- CLASS B -- baselined content facts. Drift is a finding, not a failure
-- to be edited away. When a new modality legitimately grows the question
-- universe, INSERT a new baseline row for that modality; do not UPDATE
-- the READ row.
-- =====================================================================

INSERT INTO `ff_30_marts.dq_results`
WITH actual AS (
  SELECT modality,
         COUNT(DISTINCT question_key)                              AS question_universe,
         COUNTIF(qual_text IS NOT NULL AND is_primary_run)         AS verbatim_rows,
         COUNT(DISTINCT IF(n_runs_for_question = 2,
                           FORMAT('%s|%s', archetype_id, question_key), NULL)) AS replicate_keys
  FROM `ff_20_curated.v_response_metrics`
  GROUP BY modality
),
long AS (
  SELECT modality, 'question_universe' AS metric, question_universe AS actual FROM actual
  UNION ALL SELECT modality, 'verbatim_rows',  verbatim_rows  FROM actual
  UNION ALL SELECT modality, 'replicate_keys', replicate_keys FROM actual
)
SELECT CURRENT_TIMESTAMP(),
       CASE l.metric WHEN 'question_universe' THEN 'DQ03'
                     WHEN 'verbatim_rows'     THEN 'DQ12'
                     ELSE 'DQ15' END,
       'B', l.modality,
       FORMAT('%s vs baseline set %t by %s', l.metric, b.set_on, b.set_by),
       b.expected, l.actual, l.actual = b.expected,
       CASE
         WHEN b.expected IS NULL THEN 'NO BASELINE for this modality -- set one'
         WHEN l.actual = b.expected THEN NULL
         ELSE FORMAT('drift %+d -- confirm intended, then INSERT a new baseline row',
                     l.actual - b.expected)
       END
FROM long l
LEFT JOIN `ff_00_raw.dq_baseline` b
  ON b.metric = l.metric AND b.modality = l.modality;


-- =====================================================================
-- Gate: fail the build on any red. In Dataform this is the assertion;
-- as a scheduled query, wrap in an ASSERT.
-- =====================================================================
ASSERT (
  SELECT COUNTIF(NOT passed) = 0
  FROM `ff_30_marts.dq_results`
  WHERE run_ts > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 5 MINUTE)
    AND class = 'A'          -- Class A red blocks; Class B drift reports
) AS 'DQ Class A assertion failed -- see ff_30_marts.dq_results';
