-- dim_run: one row per source file (14). A thin lookup from run_id to its
-- section and whether it is a combined (2.1X) file.
--
-- It deliberately does NOT carry the primary-run flag. Whether a run is primary
-- depends on the persona, not the file: G.1 and G.2 both live in
-- read_g_gr1_s2_1x, but only G.2 is replicated. That can only be resolved at
-- the fact grain, in fct_response.
--
-- F4: the section extractor is r's(2_\d)x?$', matching the pinned filename
-- convention read_{g|s}_{gr1|gr2}_s2_{1|2|3}[x]. The plan doc's regex expected
-- an 's' its own slugify step never produced, which returned NULL for all 12
-- rows. Capturing '2_\d' rather than 's2_\d' is what makes section_code come
-- out as '2.1' instead of 's2.1'.
--
-- creative_of_file is a property of the FILE, not of every row in it: the
-- combined 2.1X files carry two cohorts. Always take creative from
-- dim_archetype, never from the filename.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_run` AS
WITH files AS (
  SELECT _source_file FROM `${PROJECT_ID}.${DS_RAW}.raw_read_s21`
  UNION ALL
  SELECT _source_file FROM `${PROJECT_ID}.${DS_RAW}.raw_read_s22`
  UNION ALL
  SELECT _source_file FROM `${PROJECT_ID}.${DS_RAW}.raw_read_s23`
  UNION ALL
  SELECT _source_file FROM `${PROJECT_ID}.${DS_RAW}.raw_read_s14`
),
grouped AS (
  SELECT
    LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$')) AS run_id,
    ANY_VALUE(_source_file)                               AS source_file,
    COUNT(*)                                              AS n_rows
  FROM files
  GROUP BY run_id
)
SELECT
  run_id,
  source_file,
  -- Captures the major section digit too. Pinned to s2_, section 1.4's two runs
  -- returned NULL section_code -- the same F4 failure this file's header
  -- describes, reappearing the moment a non-2.x section arrived.
  REPLACE(REGEXP_EXTRACT(run_id, r's([12]_\d)x?$'), '_', '.') AS section_code,
  ENDS_WITH(run_id, 'x')                                   AS is_combined_file,
  CASE
    WHEN STARTS_WITH(run_id, 'read_g_') THEN 'Goyer'
    WHEN STARTS_WITH(run_id, 'read_s_') THEN 'Sheridan'
  END                                                      AS creative_of_file,
  n_rows
FROM grouped;
