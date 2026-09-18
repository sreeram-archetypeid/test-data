-- =====================================================================
-- banner_config DDL.  Run once per environment.  Idempotent.
--
-- Everything study-specific lives here. No .sqlx file names a study,
-- a meta, or a question.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS `archetypeid-staging.banner_config` OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS `archetypeid-staging.banner_raw`    OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS `archetypeid-staging.banner`        OPTIONS(location='US');
CREATE SCHEMA IF NOT EXISTS `archetypeid-staging.banner_assertions` OPTIONS(location='US');


-- ---------------------------------------------------------------------
-- 1. Registries
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.format_registry` (
  format_id          STRING NOT NULL,
  format_name        STRING,
  -- Regexes applied to the raw CSV column header. The envelope is fixed
  -- (persona block + optional aat block + N x 7 question block), so these
  -- are constants for the ARENA export, not per-study guesses.
  persona_col_regex  STRING,   -- r'^archetype_'
  aat_col_regex      STRING,   -- r'^aat_'
  question_col_regex STRING,   -- r'^Q(\d+)_(question|meta|type|rating_label|rating|selected|qual)$'
  id_col             STRING,   -- 'archetype_id'
  -- Applied to source_file / group_name to recover run and condition.
  run_id_regex       STRING,   -- capture group 1; NULL => single run
  cell_regex         STRING,   -- capture group 1; NULL => monadic, single cell
  cell_source        STRING,   -- 'source_file' | 'group_name'
  active             BOOL,
  notes              STRING
);

-- Q{n}_type -> how to tabulate. Verified against every row of the 15
-- reference files: type 4 is always exactly one punch, type 5 is 1-6
-- punches, type 1 is qual only, type 2 is a bare unlabelled number.
CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.type_code_map` (
  format_id      STRING NOT NULL,
  type_code      STRING NOT NULL,
  tabulation_kind STRING NOT NULL,  -- 'CODED' | 'OPEN'
  response_mode  STRING NOT NULL,   -- 'single' | 'multi' | 'none'
  value_field    STRING NOT NULL,   -- 'selected' | 'rating' | 'qual'
  has_labels     BOOL,              -- FALSE for type 2: bare numbers, no stub text
  notes          STRING
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.study_registry` (
  study_id          STRING NOT NULL,
  format_id         STRING NOT NULL,
  study_name        STRING,
  gcs_prefix        STRING,
  banner_plan_id    STRING,
  headline_meta     STRING,          -- the conversion question. No file states this.
  topbox_codes      ARRAY<INT64>,    -- which punches count as converted
  primary_run_rule  STRING,          -- 'standalone_wins' | 'latest_wins' | 'all_runs'
  status            STRING,          -- pending|ingested|profiled|configured|built|published|failed
  detected_at       TIMESTAMP,
  built_at          TIMESTAMP,
  published_at      TIMESTAMP,
  error_message     STRING
);


-- ---------------------------------------------------------------------
-- 2. Respondent attributes
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.attr_field_map` (
  format_id          STRING NOT NULL,
  study_id           STRING,
  source_field_regex STRING NOT NULL,
  attr_name          STRING NOT NULL,
  attr_role          STRING,
  attr_sort          INT64
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.attr_value_map` (
  format_id       STRING NOT NULL,
  attr_name       STRING NOT NULL,
  match_regex     STRING NOT NULL,
  canonical_value STRING NOT NULL,
  value_sort      INT64,
  rule_sort       INT64
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.age_band` (
  format_id  STRING NOT NULL,
  study_id   STRING,
  band_label STRING NOT NULL,
  age_low    INT64 NOT NULL,
  age_high   INT64 NOT NULL,
  band_sort  INT64
);


-- ---------------------------------------------------------------------
-- 3. Banner plan
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.banner_plan` (
  banner_plan_id STRING NOT NULL,
  plan_name      STRING,
  format_id      STRING,
  notes          STRING
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.cut_def` (
  banner_plan_id STRING NOT NULL,
  cut_id         STRING NOT NULL,
  banner_group   STRING,
  group_sort     INT64,
  column_label   STRING,
  column_sort    INT64,
  is_printed     BOOL,
  nest_by_cell   BOOL,
  rule_kind      STRING NOT NULL,   -- all | attr | response | and | or
  attr_name      STRING,
  attr_values    ARRAY<STRING>,
  meta           STRING,
  item_pattern   STRING,
  code_op        STRING,            -- in | lte | gte
  codes          ARRAY<INT64>,
  child_cut_ids  ARRAY<STRING>,
  min_base       INT64
);


-- ---------------------------------------------------------------------
-- 4. NETs and labels
--
-- Stub labels are NOT configured: for CODED questions they are read from
-- the data (option_code + option_label as answered). Only NETs, which are
-- an editorial grouping, and type-2 labels, which the file omits, need
-- config here.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.net_def` (
  format_id    STRING NOT NULL,
  meta         STRING NOT NULL,
  item_pattern STRING,
  net_label    STRING NOT NULL,     -- 'NET: Weekly/Monthly', 'Total Know'
  codes        ARRAY<INT64>,
  net_sort     INT64
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.rating_label_map` (
  format_id  STRING NOT NULL,
  meta       STRING NOT NULL,
  code       INT64  NOT NULL,
  label      STRING NOT NULL,
  label_sort INT64
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.base_label_map` (
  format_id  STRING NOT NULL,
  meta       STRING,
  base_label STRING NOT NULL
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.meta_phase_map` (
  format_id      STRING NOT NULL,
  meta           STRING NOT NULL,
  exposure_phase STRING,            -- pre | post | admin
  meta_sort      INT64
);


-- ---------------------------------------------------------------------
-- 5. Tunables
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.banner_params` (
  format_id   STRING NOT NULL,
  study_id    STRING,
  param_name  STRING NOT NULL,
  param_value STRING NOT NULL
);
-- Expected: age_split_at, min_cut_base, min_eta_sq, max_cast_reject_pct


-- ---------------------------------------------------------------------
-- 6. Bookkeeping
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_config.ingest_log` (
  study_id    STRING,
  gcs_uri     STRING,
  size_bytes  INT64,
  updated_at  TIMESTAMP,
  ingested_at TIMESTAMP,
  row_count   INT64,
  status      STRING
);

CREATE TABLE IF NOT EXISTS `archetypeid-staging.banner_raw.file_cell` (
  study_id    STRING,
  format_id   STRING,
  source_file STRING,
  row_ix      INT64,
  col_ordinal INT64,
  header      STRING,
  cell_value  STRING,
  ingested_at TIMESTAMP
)
PARTITION BY DATE(ingested_at)
CLUSTER BY study_id, header;
