-- =====================================================================
-- sp_unpivot_survey  --  schema-agnostic wide->long transform
--
-- Replaces tools/gen_unpivot.py (plan §7.1). The question count and facet
-- set are discovered from INFORMATION_SCHEMA at run time, so the same call
-- handles the 20/35/36-question READ sections, the AUDIO/VIDEO sections
-- whatever their length, and any future export whose blocks match the
-- supplied regexes. No regeneration step, no 91 hand-listed groups.
--
-- Adapted from the Google architecture review, §1.3 "Dynamic SQL with
-- EXECUTE IMMEDIATE: automated column discovery from INFORMATION_SCHEMA".
--
-- Preconditions
--   * Raw table loaded with every column STRING (no type inference) and
--     --allow_quoted_newlines (D1). Typing happens downstream.
--   * Raw table carries _source_file (bq load --hive_partitioning or an
--     external table with _FILE_NAME); it is what run_id derives from.
--
-- Example
--   CALL `ff_10_staging.sp_unpivot_survey`(
--     'ff_00_raw.raw_read_s22',
--     'ff_10_staging.stg_response_s22',
--     r'^Q(\d+)_',          -- idx regex, one capture group
--     r'^Q\d+_(.+)$',       -- facet regex, one capture group
--     JSON '{"question":"question_text","type":"q_type"}',
--     FALSE);
-- =====================================================================

CREATE OR REPLACE PROCEDURE `ff_10_staging.sp_unpivot_survey`(
  in_raw_table   STRING,   -- 'dataset.table'
  in_out_table   STRING,   -- 'dataset.table'
  in_idx_regex   STRING,   -- one capture group -> question index
  in_facet_regex STRING,   -- one capture group -> facet name
  in_role_map    JSON,     -- {"<facet>":"<output column>"}; unmapped = identity
  in_dry_run     BOOL      -- TRUE: log the SQL, build nothing
)
BEGIN
  DECLARE v_dataset  STRING DEFAULT SPLIT(in_raw_table, '.')[OFFSET(0)];
  DECLARE v_table    STRING DEFAULT SPLIT(in_raw_table, '.')[OFFSET(1)];
  DECLARE v_facets   ARRAY<STRING>;
  DECLARE v_n_blocks INT64;
  DECLARE v_has_src  BOOL;
  DECLARE v_decl     STRING;   -- (v_question, v_meta, ...)
  DECLARE v_select   STRING;   -- v_question AS question_text, ...
  DECLARE v_in_list  STRING;   -- (Q1_question, ...) AS 1, ...
  DECLARE v_sql      STRING;

  -- ---- 1. facets, in source ordinal order of the first block ------------
  EXECUTE IMMEDIATE FORMAT("""
    SELECT ARRAY_AGG(facet ORDER BY first_pos)
    FROM (
      SELECT REGEXP_EXTRACT(column_name, @rx) AS facet,
             MIN(ordinal_position)            AS first_pos
      FROM `%s.INFORMATION_SCHEMA.COLUMNS`
      WHERE table_name = @tbl
        AND REGEXP_CONTAINS(column_name, @rx)
      GROUP BY facet
    )""", v_dataset)
  INTO v_facets
  USING in_facet_regex AS rx, v_table AS tbl;

  IF v_facets IS NULL OR ARRAY_LENGTH(v_facets) = 0 THEN
    RAISE USING MESSAGE = FORMAT(
      'sp_unpivot_survey: no columns in %s matched facet regex %s',
      in_raw_table, in_facet_regex);
  END IF;

  EXECUTE IMMEDIATE FORMAT("""
    SELECT COUNT(DISTINCT REGEXP_EXTRACT(column_name, @rx))
    FROM `%s.INFORMATION_SCHEMA.COLUMNS`
    WHERE table_name = @tbl AND REGEXP_CONTAINS(column_name, @rx)
    """, v_dataset)
  INTO v_n_blocks
  USING in_idx_regex AS rx, v_table AS tbl;

  EXECUTE IMMEDIATE FORMAT("""
    SELECT COUNTIF(column_name = '_source_file') > 0
    FROM `%s.INFORMATION_SCHEMA.COLUMNS` WHERE table_name = @tbl
    """, v_dataset)
  INTO v_has_src USING v_table AS tbl;

  -- ---- 2. declared value columns + role aliases -------------------------
  -- Declared names are prefixed so they can never collide with an entity
  -- attribute column that happens to share a facet name.
  SET v_decl = (
    SELECT STRING_AGG(FORMAT('v_%s', f), ', ' ORDER BY o)
    FROM UNNEST(v_facets) f WITH OFFSET o);

  SET v_select = (
    SELECT STRING_AGG(
             FORMAT('v_%s AS %s', f,
                    COALESCE(JSON_VALUE(in_role_map, '$."' || f || '"'), f)),
             ',\n    ' ORDER BY o)
    FROM UNNEST(v_facets) f WITH OFFSET o);

  -- ---- 3. the IN list, one group per question block ---------------------
  EXECUTE IMMEDIATE FORMAT("""
    SELECT STRING_AGG(grp, ',\\n    ' ORDER BY idx)
    FROM (
      SELECT idx,
             FORMAT('(%%s) AS %%d', STRING_AGG(column_name ORDER BY facet_rank), idx) AS grp
      FROM (
        SELECT CAST(REGEXP_EXTRACT(column_name, @idx_rx) AS INT64) AS idx,
               column_name,
               (SELECT o FROM UNNEST(@facets) f WITH OFFSET o
                 WHERE f = REGEXP_EXTRACT(column_name, @facet_rx)) AS facet_rank
        FROM `%s.INFORMATION_SCHEMA.COLUMNS`
        WHERE table_name = @tbl AND REGEXP_CONTAINS(column_name, @idx_rx)
      )
      GROUP BY idx
      HAVING COUNT(*) = @n_facets      -- drop ragged blocks rather than fail
    )""", v_dataset)
  INTO v_in_list
  USING in_idx_regex AS idx_rx, in_facet_regex AS facet_rx, v_table AS tbl,
        v_facets AS facets, ARRAY_LENGTH(v_facets) AS n_facets;

  -- ---- 4. assemble -------------------------------------------------------
  SET v_sql = FORMAT("""
CREATE OR REPLACE TABLE `%s` AS
SELECT
    * EXCEPT(%s),
    %s,
    q_idx,
    %s AS run_id
FROM `%s`
UNPIVOT ((%s) FOR q_idx IN (
    %s
))""",
    in_out_table,
    v_decl,
    v_select,
    IF(v_has_src,
       "LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\\\\.csv$'))",
       "CAST(NULL AS STRING)"),
    in_raw_table,
    v_decl,
    v_in_list);

  SELECT FORMAT('sp_unpivot_survey: %s -> %s | %d blocks x %d facets',
                in_raw_table, in_out_table, v_n_blocks, ARRAY_LENGTH(v_facets))
         AS summary,
         v_sql AS generated_sql;

  IF NOT in_dry_run THEN
    EXECUTE IMMEDIATE v_sql;
  END IF;
END;
