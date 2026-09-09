-- ============================================================================
-- Stage 2: register and land one export. Adding a version is one CALL.
-- ============================================================================
-- Two things make this harder than a normal CSV load, and both are handled here
-- rather than left to whoever is at the keyboard:
--
-- 1. THE COLUMN COUNT DIFFERS PER EXPORT (332 / 360 / 661 in the current wave),
--    because the question count differs. So you can never wildcard-load several
--    exports into one table: it either errors on schema mismatch or silently
--    drops the provenance that makes a version comparison possible. One raw
--    table per run, always.
--
-- 2. EVERY COLUMN MUST LAND AS STRING. Autodetect would type archetype_nps_score
--    as INT64 in one export and STRING in another, and a silent load-time cast is
--    unrecoverable. But nobody is typing a 661-column schema by hand, so the
--    procedure discovers the column NAMES with a throwaway autodetected external
--    table, then rebuilds the external table with an explicit all-STRING schema.
--    Names come from the header row either way, so a mistyped probe is harmless.
-- ============================================================================

CREATE TABLE IF NOT EXISTS `PROJECT_ID.abr_20_curated.dim_run` (
  run_id STRING NOT NULL,        -- stable identity of one export = one run
  panel STRING,                  -- version-stable: instrument + panel, never the build
  instrument STRING,
  build STRING,
  export_date STRING,
  run_seq INT64,
  gcs_uri STRING,
  n_columns INT64,
  n_personas INT64,
  n_questions INT64,
  expected_fact_rows INT64,
  registered_at TIMESTAMP
);

CREATE OR REPLACE PROCEDURE `PROJECT_ID.abr_00_config.sp_register_export`(
  gcs_uri STRING,      -- e.g. 'gs://bucket/abr/v1/htr_k9_42p_0_0.csv'
  run_id STRING,       -- e.g. 'htr_k9_42p_0_0_09_01'   (letters, digits, _ only)
  panel STRING,        -- e.g. 'HTR_K9'    version-stable panel code
  instrument STRING,   -- e.g. 'HTR'
  build STRING,        -- e.g. '42p.0.0'   THIS is the version
  export_date STRING,  -- e.g. '09-01'
  run_seq INT64        -- 1 unless the same build was generated twice
)
BEGIN
  DECLARE cols ARRAY<STRING>;
  DECLARE schema_str STRING;
  DECLARE n_personas, n_questions INT64;

  IF NOT REGEXP_CONTAINS(run_id, r'^[a-z0-9_]+$') THEN
    RAISE USING MESSAGE = FORMAT(
      'run_id must be lowercase letters, digits and underscores only: %s', run_id);
  END IF;

  -- pass 1: learn the column names
  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.abr_01_raw.probe_%s`
    OPTIONS (format = 'CSV', uris = ['%s'], skip_leading_rows = 1,
             allow_quoted_newlines = true, max_bad_records = 0)
  """, run_id, gcs_uri);

  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(column_name ORDER BY ordinal_position)
    FROM `PROJECT_ID.abr_01_raw.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = 'probe_%s'
  """, run_id) INTO cols;

  IF cols IS NULL OR ARRAY_LENGTH(cols) = 0 THEN
    RAISE USING MESSAGE = FORMAT('no columns found for %s -- check the GCS uri', gcs_uri);
  END IF;
  IF NOT ('archetype_id' IN UNNEST(cols)) THEN
    RAISE USING MESSAGE = 'not a persona export: no archetype_id column';
  END IF;

  -- pass 2: same file, explicit all-STRING schema
  SET schema_str = (
    SELECT STRING_AGG(FORMAT('`%s` STRING', c), ', ')
    FROM UNNEST(cols) AS c
  );
  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE EXTERNAL TABLE `PROJECT_ID.abr_01_raw.ext_%s` (%s)
    OPTIONS (format = 'CSV', uris = ['%s'], skip_leading_rows = 1,
             allow_quoted_newlines = true, max_bad_records = 0)
  """, run_id, schema_str, gcs_uri);

  -- materialise. _FILE_NAME is only available on an external table, which is why
  -- raw is built FROM one rather than loaded directly: provenance survives.
  EXECUTE IMMEDIATE FORMAT("""
    CREATE OR REPLACE TABLE `PROJECT_ID.abr_01_raw.raw_%s` AS
    SELECT *,
           '%s' AS run_id, '%s' AS panel, '%s' AS build,
           _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
    FROM `PROJECT_ID.abr_01_raw.ext_%s`
  """, run_id, run_id, panel, build, run_id);

  EXECUTE IMMEDIATE FORMAT("DROP TABLE `PROJECT_ID.abr_01_raw.probe_%s`", run_id);

  EXECUTE IMMEDIATE FORMAT(
    "SELECT COUNT(*) FROM `PROJECT_ID.abr_01_raw.raw_%s`", run_id) INTO n_personas;
  SET n_questions = (
    SELECT COUNT(*) FROM UNNEST(cols) AS c
    WHERE REGEXP_CONTAINS(c, r'^Q[0-9]+_question$'));

  IF n_questions = 0 THEN
    RAISE USING MESSAGE = FORMAT(
      'no Q{n}_question columns in %s -- wrong file shape', gcs_uri);
  END IF;

  DELETE FROM `PROJECT_ID.abr_20_curated.dim_run` WHERE dim_run.run_id = run_id;
  INSERT INTO `PROJECT_ID.abr_20_curated.dim_run`
  VALUES (run_id, panel, instrument, build, export_date, run_seq, gcs_uri,
          ARRAY_LENGTH(cols), n_personas, n_questions, n_personas * n_questions,
          CURRENT_TIMESTAMP());

  SELECT FORMAT('registered %s: %d personas x %d questions = %d fact rows expected',
                run_id, n_personas, n_questions, n_personas * n_questions) AS result;
END;
