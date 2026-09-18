-- =====================================================================
-- Registering a drop. This is the whole of the manual step.
-- MERGE, not INSERT: safe to re-run without creating duplicate studies.
-- =====================================================================

MERGE `archetypeid-staging.banner_config.study_registry` AS t
USING (
  SELECT * FROM UNNEST([
    STRUCT(
      'drop-001' AS study_id, 'arena_ff_v1' AS format_id,
      'Fatal Fury concept test' AS study_name,
      'gs://archetypeid-drops/drop-001' AS gcs_prefix,
      'ff_ban2' AS banner_plan_id,
      'POSTINT' AS headline_meta, [1,2] AS topbox_codes,
      'standalone_wins' AS primary_run_rule),
    STRUCT(
      'drop-002', 'arena_abr_v1',
      'Air Bud Returns concept test',
      'gs://archetypeid-drops/drop-002',
      'abr_ban1',
      -- headline_meta NULL: ABR has no closed-ended conversion question.
      -- mart_conversion falls back to the aat block and flags it derived.
      CAST(NULL AS STRING), CAST(NULL AS ARRAY<INT64>),
      'all_runs')
  ])
) AS s
ON t.study_id = s.study_id
WHEN MATCHED THEN UPDATE SET
  format_id        = s.format_id,
  study_name       = s.study_name,
  gcs_prefix       = s.gcs_prefix,
  banner_plan_id   = s.banner_plan_id,
  headline_meta    = s.headline_meta,
  topbox_codes     = s.topbox_codes,
  primary_run_rule = s.primary_run_rule
WHEN NOT MATCHED THEN INSERT
  (study_id, format_id, study_name, gcs_prefix, banner_plan_id,
   headline_meta, topbox_codes, primary_run_rule, status, detected_at)
VALUES
  (s.study_id, s.format_id, s.study_name, s.gcs_prefix, s.banner_plan_id,
   s.headline_meta, s.topbox_codes, s.primary_run_rule, 'pending', CURRENT_TIMESTAMP());

-- Note: status is NOT touched on MATCHED, so re-running this never
-- resets a study that has already been built or published.


-- --- After reviewing banner.mart_study_profile -----------------------
-- Four decisions, then promote:
--   UPDATE `archetypeid-staging.banner_config.study_registry`
--      SET headline_meta = '<meta>', topbox_codes = [1,2],
--          banner_plan_id = '<plan>', status = 'configured'
--    WHERE study_id = '<drop>';
