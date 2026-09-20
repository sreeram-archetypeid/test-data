-- =====================================================================
-- Format seeds for the two formats present in drop-001 and drop-002.
-- A third format is three INSERTs, not a code change.
-- =====================================================================

DELETE FROM `archetypeid-staging.banner_config.format_registry` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.format_registry`
 (format_id, format_name, persona_col_regex, aat_col_regex, question_col_regex,
  id_col, run_id_regex, cell_regex, cell_source, active, notes)
VALUES
 ('arena_ff_v1','ARENA Fatal Fury concept test',
  r'^archetype_', NULL,
  r'^Q(\d+)_(question|meta|type|rating_label|rating|selected|qual)$',
  'archetype_id',
  r'-(\d+\.\d+X?)\s',          -- 2_1X / 2_2 / 2_3  -> replicate run
  r'-FF-([GS])-',              -- two creatives: Goyer / Sheridan
  'source_file', TRUE,
  'No aat block. POSTINT is type 4, a real closed-ended answer.'),

 ('arena_abr_v1','ARENA Air Bud Returns concept test',
  r'^archetype_', r'^aat_',
  r'^Q(\d+)_(question|meta|type|rating_label|rating|selected|qual)$',
  'archetype_id',
  NULL,                        -- single run per panel
  NULL,                        -- MONADIC: no concept split, single cell
  NULL, TRUE,
  'Monadic. Kid panels answer KPOSTINT as free text (type 1); the adult file has no interest question at all. Conversion metric is only available from the aat block and is model-derived. See RUNBOOK section 6.');


-- Q{n}_type taxonomy. Verified against 32,000+ answers in the reference
-- files; the mapping is identical for both formats.
DELETE FROM `archetypeid-staging.banner_config.type_code_map` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.type_code_map`
 (format_id, type_code, tabulation_kind, response_mode, value_field, has_labels, notes)
SELECT f.format_id, t.* FROM UNNEST([
  STRUCT('1' AS type_code,'OPEN'  AS tabulation_kind,'none'   AS response_mode,'qual'     AS value_field, FALSE AS has_labels,'Verbatim only'          AS notes),
  STRUCT('2','CODED','single','rating',   FALSE,'Bare 1-6, no labels in file; needs rating_label_map'),
  STRUCT('4','CODED','single','selected', TRUE, 'Always exactly one punch'),
  STRUCT('5','CODED','multi', 'selected', TRUE, 'Pipe-delimited, 1-6 punches')
]) AS t
CROSS JOIN (SELECT format_id FROM `archetypeid-staging.banner_config.format_registry`) AS f;


-- ---------------------------------------------------------------------
-- Respondent attributes. Five fields out of the 46-column persona block
-- are banner-relevant; the rest stay in banner_raw, unmapped.
-- ---------------------------------------------------------------------
DELETE FROM `archetypeid-staging.banner_config.attr_field_map` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.attr_field_map`
 (format_id, study_id, source_field_regex, attr_name, attr_role, attr_sort)
SELECT f.format_id, NULL, m.* FROM UNNEST([
  STRUCT(r'^archetype_age_range$'     AS source_field_regex,'age'       AS attr_name,'demographic' AS attr_role, 10 AS attr_sort),
  STRUCT(r'^archetype_gender$',        'gender',   'demographic', 11),
  STRUCT(r'^archetype_race$',          'ethnicity','demographic', 12),
  STRUCT(r'^archetype_location_type$', 'region',   'demographic', 13)
]) AS m
CROSS JOIN (SELECT format_id FROM `archetypeid-staging.banner_config.format_registry`) AS f;


DELETE FROM `archetypeid-staging.banner_config.attr_value_map` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.attr_value_map`
 (format_id, attr_name, match_regex, canonical_value, value_sort, rule_sort)
SELECT f.format_id, v.* FROM UNNEST([
  STRUCT('gender'    AS attr_name, r'^male$|^man$'   AS match_regex,'Man'   AS canonical_value, 1 AS value_sort, 1 AS rule_sort),
  STRUCT('gender',    r'^female$|^woman$',                'Woman', 2, 2),
  STRUCT('ethnicity', r'lati[nc]o|hispanic',              'Latino / Hispanic',        2, 1),
  STRUCT('ethnicity', r'black|african',                   'Black / African American', 3, 2),
  STRUCT('ethnicity', r'white|caucasian',                 'White / Caucasian',        1, 3),
  STRUCT('ethnicity', r'asian|pacific islander',          'Asian or Pacific Islander',4, 4),
  STRUCT('region',    r'urban',                           'Urban',    1, 1),
  STRUCT('region',    r'suburban',                        'Suburban', 2, 2),
  STRUCT('region',    r'rural',                           'Rural',    3, 3)
]) AS v
CROSS JOIN (SELECT format_id FROM `archetypeid-staging.banner_config.format_registry`) AS f;


-- Age bands differ by format: FF is a 13-64 adult/teen panel, ABR runs
-- kid panels at single-year granularity.
DELETE FROM `archetypeid-staging.banner_config.age_band` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.age_band`
 (format_id, study_id, band_label, age_low, age_high, band_sort)
VALUES
 ('arena_ff_v1',NULL,'13-17',13,17,1),('arena_ff_v1',NULL,'18-24',18,24,2),
 ('arena_ff_v1',NULL,'25-29',25,29,3),('arena_ff_v1',NULL,'30-34',30,34,4),
 ('arena_ff_v1',NULL,'35-39',35,39,5),('arena_ff_v1',NULL,'40-44',40,44,6),
 ('arena_ff_v1',NULL,'45-54',45,54,7),('arena_ff_v1',NULL,'55-64',55,64,8),
 ('arena_abr_v1',NULL,'4-6',   4, 6,1),('arena_abr_v1',NULL,'7-9',  7, 9,2),
 ('arena_abr_v1',NULL,'10-12',10,12,3),('arena_abr_v1',NULL,'13-17',13,17,4),
 ('arena_abr_v1',NULL,'18-34',18,34,5),('arena_abr_v1',NULL,'35-54',35,54,6),
 ('arena_abr_v1',NULL,'55+',  55,120,7);


DELETE FROM `archetypeid-staging.banner_config.banner_params` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.banner_params`
 (format_id, study_id, param_name, param_value)
VALUES
 ('arena_ff_v1', NULL,'age_split_at','35'),
 ('arena_ff_v1', NULL,'min_cut_base','30'),
 ('arena_ff_v1', NULL,'min_eta_sq','0.01'),
 ('arena_ff_v1', NULL,'max_cast_reject_pct','0.5'),
 ('arena_abr_v1',NULL,'age_split_at','10'),
 ('arena_abr_v1',NULL,'min_cut_base','20'),
 ('arena_abr_v1',NULL,'min_eta_sq','0.01'),
 ('arena_abr_v1',NULL,'max_cast_reject_pct','0.5');


DELETE FROM `archetypeid-staging.banner_config.base_label_map` WHERE format_id IN ('arena_ff_v1','arena_abr_v1');
INSERT INTO `archetypeid-staging.banner_config.base_label_map`
 (format_id, meta, base_label)
VALUES
 ('arena_ff_v1', NULL,      'Total Respondents'),
 ('arena_ff_v1','PRELIKE1','KNOW SOUTHTOWN GAMES'),
 ('arena_ff_v1','PRELIKE2','KNOW SOUTHTOWN GAMES'),
 ('arena_ff_v1','VGFRAN2', 'HEARD OF FRANCHISE'),
 ('arena_abr_v1',NULL,     'Total Respondents');
