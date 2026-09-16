-- STEP 2 checklist (run in BigQuery console)
-- 1) Confirm vars target exists in registry
SELECT study_id, format_id, gcs_uri, status
FROM `archetypeid-staging.svy_config.study_registry`
ORDER BY study_id;

SELECT format_id, adapter_name, active
FROM `archetypeid-staging.svy_config.format_registry`
ORDER BY format_id;

-- 2) After you change Dataform files: search the repo UI for these strings
--    drop-001
--    arena_ff_v1   (ok ONLY inside format-specific adapters, not in mart_stubs/export)
--    -FF-
--    study_id = 'drop

-- 3) Smoke: with vars study_id=drop-001, format_id=arena_ff_v1, FF marts still build
-- 4) Smoke: with vars study_id=drop-002, format_id=abr_persona_v1, expect FF-specific
--    adapters to skip/empty until Step 3 ABR adapter exists — should NOT require SQL edits
