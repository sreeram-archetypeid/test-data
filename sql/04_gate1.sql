-- GATE 1: stop here if these are not exact.
WITH counts AS (
  SELECT 'raw_read_s21' AS tbl, COUNT(*) AS n, 596 AS target FROM `ff_00_raw.raw_read_s21`
  UNION ALL SELECT 'raw_read_s22', COUNT(*), 398 FROM `ff_00_raw.raw_read_s22`
  UNION ALL SELECT 'raw_read_s23', COUNT(*), 398 FROM `ff_00_raw.raw_read_s23`
),
files AS (
  SELECT COUNT(DISTINCT _source_file) AS n FROM (
    SELECT _source_file FROM `ff_00_raw.raw_read_s21`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s22`
    UNION ALL SELECT _source_file FROM `ff_00_raw.raw_read_s23`)
)
SELECT tbl AS check_name, n AS got, target AS want, n = target AS passed FROM counts
UNION ALL SELECT 'total_rows', (SELECT SUM(n) FROM counts), 1392,
                 (SELECT SUM(n) FROM counts) = 1392
UNION ALL SELECT 'distinct_source_files', (SELECT n FROM files), 12,
                 (SELECT n FROM files) = 12
ORDER BY check_name;
