-- Ensure FF banner age split (drop-001 / arena_ff_v1). Run once in BigQuery.

INSERT INTO `archetypeid-staging.svy_config.banner_params`
  (study_id, format_id, param_name, param_value, signed_by, signed_at)
SELECT
  CAST(NULL AS STRING),
  'arena_ff_v1',
  'age_split_at',
  '35',
  'restore',
  CURRENT_TIMESTAMP()
FROM UNNEST([1])
WHERE NOT EXISTS (
  SELECT 1
  FROM `archetypeid-staging.svy_config.banner_params`
  WHERE format_id = 'arena_ff_v1'
    AND param_name = 'age_split_at'
);

SELECT *
FROM `archetypeid-staging.svy_config.banner_params`
WHERE format_id = 'arena_ff_v1';
