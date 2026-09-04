-- ref_wtabs: the human N=800 study, as a joinable BigQuery table.
--
-- Grain: one row per CELL of the human crosstabs --
--   (banner, table_no, item, metric_label, banner_group, banner_concept,
--    banner_col).
-- 99,231 rows across 152 tables in the two banners.
--
-- Why this exists. tools/build_comparison_csv.py already joins their numbers to
-- ours locally and credential-free, and that stays the reproducible artifact.
-- What it cannot do is let someone else query the comparison, or join it to a
-- mart, without running Python. This table is that -- and sql/50 is the join.
--
-- Source: ref/wtabs_cells.csv, produced by tools/extract_wtabs.py from the four
-- CSVs in `Final W Tabs (1)/`. That file is gitignored (16.8MB of derived
-- numbers) and regenerates deterministically, so it is staged to GCS rather
-- than committed. The reviewable artifacts are the script and
-- ref/wtabs_tables.csv.
--
-- Everything lands as STRING and is cast here, for the same reason as
-- 01_raw_*: autodetect types the same column differently across files, and the
-- casting rules belong somewhere visible.
--
-- Two columns worth knowing:
--
--   src_pct / src_freq  the value exactly as printed in their file, kept so a
--                       parsed number can always be traced back to the page it
--                       came from. Percentages there are whole integers, which
--                       is why a NET can differ from the sum of its members by
--                       up to 0.5pp per member.
--
--   is_net              their roll-up rows ('NET: Weekly/Monthly'). A NET is
--                       the union of the indented rows beneath it, NOT an
--                       answer option, so anything joining on option labels
--                       must exclude these or it will match nothing and, worse,
--                       may report a zero.

CREATE OR REPLACE EXTERNAL TABLE `${PROJECT_ID}.${DS_RAW}.ext_ref_wtabs` (
  banner          STRING,
  table_no        STRING,
  item            STRING,
  metric_label    STRING,
  row_label       STRING,
  banner_group    STRING,
  banner_concept  STRING,
  banner_col      STRING,
  banner_base_n   STRING,
  is_sigma        STRING,
  is_net          STRING,
  freq            STRING,
  pct             STRING,
  src_freq        STRING,
  src_pct         STRING
)
OPTIONS (
  format = 'CSV',
  uris = ['${GCS_REF_PREFIX}/wtabs_cells.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = true,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8',
  max_bad_records = 0
);

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.ref_wtabs`
CLUSTER BY banner, table_no, banner_group AS
SELECT
  banner,
  CAST(table_no AS INT64)                       AS table_no,
  NULLIF(item, '')                              AS item,
  metric_label,
  row_label,
  banner_group,
  NULLIF(banner_concept, '')                    AS banner_concept,
  banner_col,
  SAFE_CAST(banner_base_n AS INT64)             AS banner_base_n,
  LOWER(is_sigma) = 'true'                      AS is_sigma,
  LOWER(is_net)   = 'true'                      AS is_net,
  SAFE_CAST(freq AS FLOAT64)                    AS freq,
  SAFE_CAST(pct  AS FLOAT64)                    AS pct,
  src_freq,
  src_pct
FROM `${PROJECT_ID}.${DS_RAW}.ext_ref_wtabs`;

-- ---------------------------------------------------------------------------
-- ref_wtab_crosswalk: their (meta, battery item) -> our question_key.
--
-- Produced by tools/build_wtab_crosswalk.py, which grades its own confidence:
-- every row carries a match_method and a needs_review flag, because §12 of the
-- migration plan is right that the wording differs and half-right that it
-- cannot be automated. The meta is a literal prefix on their table titles, so
-- that part is mechanical; the battery item is not, because our question_text
-- embeds the item in a sentence while theirs gives it bare:
--
--     ours    How do you feel about the Martial Arts genre of movies/TV series?
--     W-Tabs  ** Martial Arts **
--
-- Unlike wtabs_cells.csv this file IS committed (340 rows), so it is reviewable
-- in a diff. It is staged here only so the warehouse can join to it.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE EXTERNAL TABLE `${PROJECT_ID}.${DS_RAW}.ext_ref_crosswalk` (
  wtab_meta        STRING,
  wtab_item        STRING,
  target_class     STRING,
  our_meta         STRING,
  question_text    STRING,
  question_key     STRING,
  q_type           STRING,
  archetype_column STRING,
  match_method     STRING,
  needs_review     STRING,
  note             STRING
)
OPTIONS (
  format = 'CSV',
  uris = ['${GCS_REF_PREFIX}/wtabs_crosswalk.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = true,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8',
  max_bad_records = 0
);

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.ref_wtab_crosswalk` AS
SELECT
  wtab_meta,
  NULLIF(wtab_item, '')        AS wtab_item,
  target_class,
  NULLIF(our_meta, '')         AS our_meta,
  NULLIF(question_text, '')    AS question_text,
  NULLIF(question_key, '')     AS question_key,
  NULLIF(q_type, '')           AS q_type,
  NULLIF(archetype_column, '') AS archetype_column,
  match_method,
  LOWER(needs_review) = 'yes'  AS needs_review,
  NULLIF(note, '')             AS note
FROM `${PROJECT_ID}.${DS_RAW}.ext_ref_crosswalk`;

-- ---------------------------------------------------------------------------
-- ref_wtab_tables: one row per human table (152), carrying its meta and layout.
--
-- ref_wtabs holds cells and knows only its table_no; the crosswalk keys on
-- (wtab_meta, wtab_item). This is the bridge between them, so it is required
-- for any join and not merely descriptive.
--
-- `layout` is load-bearing and was the hardest thing in the parser to get
-- right. It must be classified STRUCTURALLY, on whether the table carries a
-- SIGMA row, never on the marker text: Table 40 says
-- "** 'Definitely interested' Summary Table **" while Table 34 says
-- "** I am very much a fan **" for exactly the same shape. Classifying on the
-- words would have swapped item and metric across VGFRAN2 and GFAN1.
--
--   per_item  a distribution for one battery item  (marker + SIGMA)
--   summary   one metric across every item         (marker, no SIGMA)
--   plain     a single question                    (no marker)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE EXTERNAL TABLE `${PROJECT_ID}.${DS_RAW}.ext_ref_tables` (
  banner         STRING,
  table_no       STRING,
  meta           STRING,
  layout         STRING,
  marker         STRING,
  base_stmt      STRING,
  question_title STRING
)
OPTIONS (
  format = 'CSV',
  uris = ['${GCS_REF_PREFIX}/wtabs_tables.csv'],
  skip_leading_rows = 1,
  allow_quoted_newlines = true,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8',
  max_bad_records = 0
);

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.ref_wtab_tables` AS
SELECT
  banner,
  CAST(table_no AS INT64)   AS table_no,
  meta,
  layout,
  NULLIF(marker, '')        AS marker,
  NULLIF(base_stmt, '')     AS base_stmt,
  question_title
FROM `${PROJECT_ID}.${DS_RAW}.ext_ref_tables`;
