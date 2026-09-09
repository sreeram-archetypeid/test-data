-- ============================================================================
-- Stage 3: wide to long, generated from the table's own schema.
-- ============================================================================
-- This is the step that cannot be written once by hand and reused, because the
-- number of question blocks differs per export (83 / 40 / 36 in the current
-- wave). So it is generated: the procedure reads INFORMATION_SCHEMA for the raw
-- table, builds one SELECT per Q{n} block, and EXECUTE IMMEDIATEs the union.
--
-- One source row of 661 columns becomes 83 fact rows. After this, "what is top
-- box on appeal" is `WHERE meta = 'POSTAPPEAL'` instead of knowing that appeal
-- happens to be Q13 in one file and absent from another.
--
-- Idempotent per run: re-running replaces that run's rows and touches no other.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `PROJECT_ID.abr_10_staging.stg_response` (
  archetype_id STRING,
  run_id STRING,
  panel STRING,
  build STRING,
  q_position INT64,        -- POSITIONAL. Not question identity.
  meta STRING,
  question_text STRING,
  q_type STRING,           -- 1 open end, 4 single select, 5 multi select
  rating_raw STRING,
  selected_raw STRING,
  qual_raw STRING,
  source_file STRING
)
CLUSTER BY run_id, meta;
-- Clustering only, deliberately no partitioning. The whole wave is ~35k fact
-- rows; date partitions of a few hundred rows each would cost more and scan
-- more, not less. Revisit if this ever crosses ~10M rows.

CREATE OR REPLACE PROCEDURE `PROJECT_ID.abr_00_config.sp_unpivot`(run_id STRING)
BEGIN
  DECLARE cols ARRAY<STRING>;
  DECLARE positions ARRAY<INT64>;
  DECLARE sql STRING;
  DECLARE landed, expected INT64;

  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(column_name)
    FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'raw_%s'
  """, run_id) INTO cols;

  IF cols IS NULL THEN
    RAISE USING MESSAGE = FORMAT(
      'raw_%s does not exist -- call sp_register_export first', run_id);
  END IF;

  SET positions = (
    SELECT ARRAY_AGG(DISTINCT CAST(REGEXP_EXTRACT(c, r'^Q([0-9]+)_') AS INT64)
                     ORDER BY CAST(REGEXP_EXTRACT(c, r'^Q([0-9]+)_') AS INT64))
    FROM UNNEST(cols) AS c
    WHERE REGEXP_CONTAINS(c, r'^Q[0-9]+_question$'));

  -- One SELECT per question block. A channel column that is absent in this
  -- export becomes NULL rather than an error, so a shorter instrument still
  -- lands without special-casing.
  SET sql = (
    SELECT STRING_AGG(
      FORMAT("""SELECT archetype_id, run_id, panel, build, %d AS q_position,
       %s AS meta, %s AS question_text, %s AS q_type,
       %s AS rating_raw, %s AS selected_raw, %s AS qual_raw, _source_file
FROM `PROJECT_ID.abr_01_raw.raw_%s`""",
        pos,
        IF(FORMAT('Q%d_meta', pos)      IN UNNEST(cols), FORMAT('Q%d_meta', pos),      'CAST(NULL AS STRING)'),
        IF(FORMAT('Q%d_question', pos)  IN UNNEST(cols), FORMAT('Q%d_question', pos),  'CAST(NULL AS STRING)'),
        IF(FORMAT('Q%d_type', pos)      IN UNNEST(cols), FORMAT('Q%d_type', pos),      'CAST(NULL AS STRING)'),
        IF(FORMAT('Q%d_rating', pos)    IN UNNEST(cols), FORMAT('Q%d_rating', pos),    'CAST(NULL AS STRING)'),
        IF(FORMAT('Q%d_selected', pos)  IN UNNEST(cols), FORMAT('Q%d_selected', pos),  'CAST(NULL AS STRING)'),
        IF(FORMAT('Q%d_qual', pos)      IN UNNEST(cols), FORMAT('Q%d_qual', pos),      'CAST(NULL AS STRING)'),
        run_id),
      '\nUNION ALL\n' ORDER BY pos)
    FROM UNNEST(positions) AS pos);

  IF sql IS NULL THEN
    RAISE USING MESSAGE = FORMAT('no Q{n}_question columns in raw_%s', run_id);
  END IF;

  DELETE FROM `PROJECT_ID.abr_10_staging.stg_response` AS s WHERE s.run_id = run_id;
  EXECUTE IMMEDIATE FORMAT(
    'INSERT INTO `PROJECT_ID.abr_10_staging.stg_response` (%s)', sql);

  -- Gate. Fact rows must equal personas x questions, exactly. Anything else is
  -- a bug in the reshape, not noise -- stop here rather than analyse it.
  EXECUTE IMMEDIATE FORMAT("""
    SELECT COUNT(*) FROM `PROJECT_ID.abr_10_staging.stg_response`
    WHERE run_id = '%s'""", run_id) INTO landed;
  SET expected = (SELECT expected_fact_rows
                  FROM `PROJECT_ID.abr_20_curated.dim_run` AS r
                  WHERE r.run_id = run_id);
  IF landed != expected THEN
    RAISE USING MESSAGE = FORMAT(
      'reshape gate failed for %s: landed %d fact rows, expected %d',
      run_id, landed, expected);
  END IF;

  SELECT FORMAT('unpivoted %s: %d fact rows across %d question blocks',
                run_id, landed, ARRAY_LENGTH(positions)) AS result;
END;
