import pathlib

p = pathlib.Path("definitions/04_marts/mart_banner_render.sqlx")
s = p.read_text()

# --- 1. threshold from config, defaulting to 30 ---------------------
old = """WITH
-- Column spine, ordered as printed."""
new = """WITH
-- Columns below this base get a * on their heading and a footnote.
-- Suppression (min_base) removes a column entirely; flagging keeps it
-- visible but marks it as too thin to read as a percentage.
small_base AS (
  SELECT r.study_id,
         IFNULL(MAX(CAST(p.param_value AS INT64)), 30) AS threshold
  FROM `archetypeid-staging.banner_config.study_registry` AS r
  LEFT JOIN `archetypeid-staging.banner_config.banner_params` AS p
    ON p.format_id = r.format_id
   AND (p.study_id IS NULL OR p.study_id = r.study_id)
   AND p.param_name = 'small_base_flag'
  GROUP BY r.study_id
),

-- Column spine, ordered as printed."""
assert old in s, "small_base anchor not found"
s = s.replace(old, new, 1)

# --- 2. star the column heading -------------------------------------
old = """        WHEN 'band_cell'  THEN IFNULL(c.cell_label, '')
        ELSE c.column_label
      END"""
new = """        WHEN 'band_cell'  THEN IFNULL(c.cell_label, '')
        ELSE CONCAT(c.column_label, IF(c.n_col < sb.threshold, ' *', ''))
      END"""
assert old in s, "band label anchor not found"
s = s.replace(old, new, 1)

old = """  JOIN col_ix AS c ON c.study_id = t.study_id
  GROUP BY t.study_id, t.table_no, k.line_sort, k.line_kind"""
new = """  JOIN col_ix AS c ON c.study_id = t.study_id
  JOIN small_base AS sb ON sb.study_id = t.study_id
  GROUP BY t.study_id, t.table_no, k.line_sort, k.line_kind"""
assert old in s, "band join anchor not found"
s = s.replace(old, new, 1)

# --- 3. footnote line, once per table, only where it applies --------
old = """all_lines AS (
  SELECT * FROM titles
  UNION ALL SELECT * FROM band
  UNION ALL SELECT * FROM figures
)"""
new = """footnote AS (
  SELECT
    t.study_id, t.table_no,
    99999 AS line_sort,
    CONCAT('* Base under ', CAST(sb.threshold AS STRING),
           '. Percentages shown for information only; read the base, not the percent.') AS line_label,
    'footnote' AS line_kind,
    ARRAY<STRING>[] AS cells
  FROM tables AS t
  JOIN small_base AS sb ON sb.study_id = t.study_id
  WHERE EXISTS (
    SELECT 1 FROM col_ix AS c
    WHERE c.study_id = t.study_id AND c.n_col < sb.threshold
  )
),

all_lines AS (
  SELECT * FROM titles
  UNION ALL SELECT * FROM band
  UNION ALL SELECT * FROM figures
  UNION ALL SELECT * FROM footnote
)"""
assert old in s, "all_lines anchor not found"
s = s.replace(old, new, 1)

p.write_text(s)
print("patched mart_banner_render: small-base flag + footnote")