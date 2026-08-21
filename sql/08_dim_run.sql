-- 12 rows: one per source file. run_id is what makes the 2.1X replicate
-- explicit; it is derived from _source_file captured at materialise time.
CREATE OR REPLACE TABLE `ff_20_curated.dim_run` AS
SELECT
  run_id,
  source_file,
  REPLACE(REGEXP_EXTRACT(run_id, r'(2_\d)x?$'), '_', '.') AS section_code,
  ENDS_WITH(run_id, 'x')                                  AS is_combined_file,
  CASE WHEN REGEXP_CONTAINS(run_id, r'_g_') THEN 'Goyer'
       ELSE 'Sheridan' END                                AS creative_of_file,
  n_rows
FROM (
  SELECT
    LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$')) AS run_id,
    ANY_VALUE(_source_file)                               AS source_file,
    COUNT(*)                                              AS n_rows
  FROM (
    SELECT _source_file FROM `ff_00_raw.raw_read_s21`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s22`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s23`
  )
  GROUP BY run_id
);
