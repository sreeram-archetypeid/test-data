-- ============================================================================
-- Stage 10: one procedure that runs the whole thing.
-- ============================================================================
-- Registering and unpivoting is per export; everything after that is a rebuild
-- over whatever is registered. So adding a version is:
--
--   CALL `PROJECT_ID.abr_00_config.sp_register_export`(
--     'gs://BUCKET/abr/v2/htr_k9_43p_1_0.csv', 'htr_k9_43p_1_0',
--     'HTR_K9', 'HTR', '43p.1.0', '10-15', 1);
--   CALL `PROJECT_ID.abr_00_config.sp_unpivot`('htr_k9_43p_1_0');
--   CALL `PROJECT_ID.abr_00_config.sp_rebuild`();
--
-- Note the panel code: HTR_K9, the SAME code the earlier build carries. That is
-- what makes the two joinable in mart_run_comparison. Give it a new panel code
-- and you get two unrelated panels instead of a version pair.
--
-- sp_rebuild does NOT re-run the config or the UDFs. Those are the analysis
-- contract: they change when you decide they change, in git, not as a side
-- effect of loading data.
-- ============================================================================

CREATE OR REPLACE PROCEDURE `PROJECT_ID.abr_00_config.sp_rebuild`()
BEGIN
  CALL `PROJECT_ID.abr_00_config.sp_build_persona_dims`();
  -- 04_curated, 05_scale_map, 06_themes, 07_prose, 08_marts are plain scripts;
  -- BigQuery cannot @include a file, so run them in order with bq/run_bq.sh, or
  -- paste the CREATE statements into this procedure body once the contents have
  -- stopped changing. Keeping them as files means every rebuild is reviewable
  -- as a diff, which is why they are files.
  SELECT 'persona dims rebuilt -- now run 04 through 09 in order' AS result;
END;

-- Everything registered, and how the runs relate. Read this first on any
-- session: it tells you which comparisons the data can support.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_30_marts.v_run_relationships` AS
SELECT
  a.run_id AS run_a, b.run_id AS run_b, a.panel, a.build AS build_a, b.build AS build_b,
  CASE
    WHEN a.panel = b.panel AND a.build != b.build THEN 'version'
    WHEN a.panel = b.panel AND a.build = b.build AND a.run_seq != b.run_seq THEN 'replicate'
    WHEN a.build = b.build AND a.instrument = b.instrument THEN 'wave_sibling'
    ELSE 'cross_instrument'
  END AS kind,
  (SELECT COUNT(*) FROM (
     SELECT `PROJECT_ID.abr_00_config.fn_norm_text`(question_text) AS t
     FROM `PROJECT_ID.abr_20_curated.dim_question` WHERE run_id = a.run_id
     INTERSECT DISTINCT
     SELECT `PROJECT_ID.abr_00_config.fn_norm_text`(question_text)
     FROM `PROJECT_ID.abr_20_curated.dim_question` WHERE run_id = b.run_id)) AS shared_wording,
  a.n_questions AS questions_a, b.n_questions AS questions_b,
  a.n_personas AS personas_a, b.n_personas AS personas_b
FROM `PROJECT_ID.abr_20_curated.dim_run` a
JOIN `PROJECT_ID.abr_20_curated.dim_run` b ON a.run_id < b.run_id;
