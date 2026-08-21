#!/usr/bin/env python3
"""Execute the ARENA FF transform chain locally in DuckDB and run the DQ suite.

Purpose: prove Gates 2/3/4 and DQ01-DQ16 against the real source CSVs *before*
spending anything on GCP. Every parse rule here mirrors the BigQuery SQL in
BIGQUERY_MIGRATION_PLAN.md Sections 6-8, so a green run means the contract is
sound and any BigQuery failure is an environment or dialect problem, not a
logic problem.

This is a validation harness, not the pipeline. BigQuery remains the system of
record; DuckDB is used only because it runs the same relational logic offline.

Dialect substitutions (DuckDB <- BigQuery):
  SAFE_CAST   -> TRY_CAST          TO_HEX(MD5(x))  -> md5(x)
  COUNTIF     -> count_if          SPLIT           -> str_split
  INITCAP     -> upper/lower slice (DuckDB has no initcap)

Usage:
  python3 tools/validate_local.py ["Written Descriptions_2026_08_7"]
"""
import glob
import os
import sys

try:
    import duckdb
except ImportError:
    sys.exit("duckdb required: pip install duckdb")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_raw_schema import ATTRIBUTE_COLUMNS  # noqa: E402

DEFAULT_SRC = "Written Descriptions_2026_08_7"
SECTIONS = {"s21": (20, "2.1"), "s22": (35, "2.2"), "s23": (36, "2.3")}
BLOCK = ["question", "meta", "type", "rating_label", "rating", "selected", "qual"]
OUT = ["question_text", "meta", "q_type", "rating_label", "rating", "selected", "qual"]

# Expected values, all derived from source in Plan Sections 1.1 and 7.3.
EXPECT = {
    "fact_rows": 40178, "personas": 398, "questions": 91, "metas": 36,
    "distinct_keys": 36218, "primary_rows": 36218, "replicate_rows": 7920,
    "replicate_keys": 3960, "verbatims": 17301,
    # 22 PERSONAS carry age_raw='17-24'. The plan's D4 quotes 81, which is the
    # count at RAW FILE-ROW grain (a persona appears in 3-4 files). At
    # dim_archetype grain the correct value is 22; 81 here fires a false alarm.
    "imputed_age": 22, "imputed_age_raw_rows": 81,
    # 3 open-end rows genuinely have no verbatim (see DQ08). Pinned so the test
    # catches NEW gaps rather than re-reporting these three forever.
    "missing_qual": 3,
    "runs": 12, "raw_rows": 1392,
}
COHORT_N = {"G.1": 100, "G.2": 100, "S.1": 98, "S.2": 100}


def section_of(path):
    import re
    m = re.search(r"-(2\.\d)X?\s", os.path.basename(path))
    return {"2.1": "s21", "2.2": "s22", "2.3": "s23"}.get(m.group(1)) if m else None


def build(con, src):
    files = sorted(glob.glob(os.path.join(src, "*.csv")))
    by_section = {}
    for p in files:
        s = section_of(p)
        if s:
            by_section.setdefault(s, []).append(p)

    # ---- 00_raw: all columns VARCHAR, provenance stamped (mirrors _FILE_NAME) ----
    # Read one file at a time. DuckDB's multi-file CSV sniffer mis-reads this set
    # (the 12 headers are in fact byte-identical - preflight_check.py proves it),
    # and per-file reads sidestep it entirely.
    for suffix, paths in by_section.items():
        for i, p in enumerate(paths):
            q = (f"SELECT *, filename AS _source_file FROM read_csv("
                 f"'{p}', header=true, all_varchar=true, filename=true)")
            con.execute(f"CREATE OR REPLACE TABLE raw_read_{suffix} AS {q}"
                        if i == 0 else f"INSERT INTO raw_read_{suffix} {q}")

    # ---- 10_staging: the unpivot (wide -> long), one UNION ALL arm per slot ----
    for suffix, (n, section_code) in SECTIONS.items():
        arms = []
        for i in range(1, n + 1):
            cols = ", ".join(f'"Q{i}_{b}" AS {o}' for b, o in zip(BLOCK, OUT))
            arms.append(
                f"SELECT archetype_id, lower(regexp_extract(_source_file, "
                f"'([^/]+)\\.csv$', 1)) AS run_id, {i} AS q_idx, {cols} "
                f"FROM raw_read_{suffix}")
        con.execute(f"CREATE OR REPLACE TABLE stg_response_{suffix} AS "
                    + "\nUNION ALL\n".join(arms))

    # ---- 10_staging: parse and type (D2, D3, D7, D11) ----
    union = "\nUNION ALL\n".join(
        f"SELECT *, '{code}' AS section_code FROM stg_response_{s}"
        for s, (_, code) in SECTIONS.items())
    con.execute(f"""
        CREATE OR REPLACE TABLE stg_response AS
        WITH all_sections AS ({union})
        SELECT
          archetype_id, run_id, section_code, q_idx,
          meta, question_text, q_type,
          md5(meta || '||' || question_text) AS question_key,
          rating_label,
          TRY_CAST(nullif(trim(rating), '') AS BIGINT) AS rating_value,
          nullif(selected, '') AS selected_raw,
          -- D2 + D3: split multi-select, strip single OR doubled code prefix
          list_transform(
            list_filter(str_split(coalesce(selected, ''), '|'),
                        x -> trim(x) <> ''),
            opt -> struct_pack(
              option_code := TRY_CAST(regexp_extract(opt, '^\\s*(\\d+)\\.', 1) AS BIGINT),
              option_label := trim(regexp_replace(opt, '^\\s*\\d+\\.\\s*(\\d+\\.\\s*)?', ''))
            )
          ) AS selected_options,
          nullif(qual, '') AS qual_text,
          length(coalesce(qual, '')) AS qual_len,
          -- D7: normalised copy for grouping only; qual_text stays verbatim
          nullif(replace(replace(qual, '’', ''''), '“', '"'), '') AS qual_text_norm
        FROM all_sections
        WHERE question_text IS NOT NULL AND question_text <> ''
    """)

    # ---- 20_curated: dim_archetype (D4, D5, D6, D11) ----
    # NOTE: the 46 attribute columns are projected INSIDE each union arm.
    # raw_read_s22 and raw_read_s23 have 291 and 298 data columns, so the
    # plan's `SELECT * EXCEPT(...) UNION DISTINCT` cannot bind. Projecting
    # first makes the arity equal and the union meaningful.
    attr_list = ", ".join(ATTRIBUTE_COLUMNS)
    con.execute("""
        CREATE OR REPLACE TABLE dim_archetype AS
        WITH attrs AS (
          SELECT __ATTRS__ FROM raw_read_s22
          UNION DISTINCT
          SELECT __ATTRS__ FROM raw_read_s23
        )
        SELECT
          archetype_id, group_name, sample_name,
          'READ' AS modality,
          CASE WHEN regexp_matches(group_name, '-G-') THEN 'Goyer'
               WHEN regexp_matches(group_name, '-S-') THEN 'Sheridan' END AS creative,
          (CASE WHEN regexp_matches(group_name, '-G-') THEN 'G' ELSE 'S' END)
            || '.' || regexp_extract(group_name, '\\.(\\d)$', 1) AS cohort_code,
          -- D5 gender: INITCAP equivalent
          upper(substr(trim(archetype_gender), 1, 1))
            || lower(substr(trim(archetype_gender), 2)) AS gender_clean,
          -- D4 age
          archetype_age_range AS age_raw,
          TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})(?:\\s|$|\\s*\\()', 1)
                   AS BIGINT) AS age_exact,
          CASE
            WHEN regexp_matches(archetype_age_range, '^\\d{1,2}(\\s*\\(|$)') THEN
              CASE
                WHEN TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})', 1) AS BIGINT) <= 17 THEN '13-17'
                WHEN TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})', 1) AS BIGINT) <= 24 THEN '18-24'
                WHEN TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})', 1) AS BIGINT) <= 34 THEN '25-34'
                WHEN TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})', 1) AS BIGINT) <= 44 THEN '35-44'
                WHEN TRY_CAST(regexp_extract(archetype_age_range, '^(\\d{1,2})', 1) AS BIGINT) <= 54 THEN '45-54'
                ELSE '55-64' END
            WHEN archetype_age_range = '13-16' THEN '13-17'
            WHEN archetype_age_range = '17-24' THEN '18-24'   -- imputed, see D4
            WHEN archetype_age_range IN ('25-29','30-34') THEN '25-34'
            WHEN archetype_age_range IN ('35-39','40-44') THEN '35-44'
            WHEN archetype_age_range = '45-54' THEN '45-54'
            WHEN archetype_age_range = '55-64' THEN '55-64'
          END AS age_band_banner,
          (archetype_age_range = '17-24') AS age_band_is_imputed,
          -- D6 income
          TRY_CAST(replace(regexp_extract(archetype_income_range, '^\\$([\\d,]+)', 1), ',', '')
                   AS BIGINT) AS income_low_usd,
          coalesce(
            TRY_CAST(replace(regexp_extract(archetype_income_range, '-\\s*\\$([\\d,]+)', 1), ',', '') AS BIGINT),
            TRY_CAST(replace(regexp_extract(archetype_income_range, '^\\$([\\d,]+)', 1), ',', '') AS BIGINT)
          ) AS income_high_usd,
          -- D11 NPS
          TRY_CAST(archetype_nps_score AS BIGINT) AS nps_score,
          CASE WHEN TRY_CAST(archetype_nps_score AS BIGINT) >= 9 THEN 'Promoter'
               WHEN TRY_CAST(archetype_nps_score AS BIGINT) >= 7 THEN 'Passive'
               ELSE 'Detractor' END AS nps_band,
          (archetype_children_status <> 'no_children') AS is_parent
        FROM attrs
    """.replace("__ATTRS__", attr_list))

    # ---- 20_curated: dim_run ----
    con.execute("""
        CREATE OR REPLACE TABLE dim_run AS
        SELECT run_id, source_file,
               replace(regexp_extract(run_id, '(2_\\d)x?$', 1), '_', '.') AS section_code,
               ends_with(run_id, 'x') AS is_combined_file,
               n_rows
        FROM (
          SELECT lower(regexp_extract(_source_file, '([^/]+)\\.csv$', 1)) AS run_id,
                 any_value(_source_file) AS source_file, COUNT(*) AS n_rows
          FROM (SELECT _source_file FROM raw_read_s21
                UNION ALL SELECT _source_file FROM raw_read_s22
                UNION ALL SELECT _source_file FROM raw_read_s23)
          GROUP BY 1)
    """)

    # ---- 20_curated: dim_question / dim_question_option ----
    con.execute("""
        CREATE OR REPLACE TABLE dim_question AS
        WITH sel AS (
          SELECT meta, question_text, MAX(len(selected_options)) AS max_selected
          FROM stg_response GROUP BY 1, 2
        )
        SELECT md5(t.meta || '||' || t.question_text) AS question_key,
               t.meta, t.question_text, t.q_type,
               -- C3: >1 option ever picked => multi-select => box metrics are
               -- meaningless (primary_code = MIN(code) is arbitrary there).
               (sel.max_selected > 1) AS is_multi_select,
               CASE t.q_type WHEN '1' THEN 'open_end'
                             WHEN '2' THEN 'numeric_rating'
                             WHEN '4' THEN 'closed_select'
                             WHEN '5' THEN 'select_plus_verbatim' END AS question_kind
        FROM (SELECT DISTINCT meta, question_text, q_type FROM stg_response) t
        JOIN sel ON sel.meta = t.meta AND sel.question_text = t.question_text
    """)
    con.execute("""
        CREATE OR REPLACE TABLE dim_question_option AS
        WITH opts AS (
          SELECT DISTINCT r.question_key, o.option_code, o.option_label
          FROM stg_response r, UNNEST(r.selected_options) AS t(o)
          WHERE o.option_code IS NOT NULL
        )
        SELECT question_key, option_code, option_label,
               option_code >= 90 AS is_sentinel,
               max(CASE WHEN option_code >= 90 THEN NULL ELSE option_code END)
                 OVER (PARTITION BY question_key) AS scale_max
        FROM opts
    """)

    # ---- 20_curated: fct_response (the analysis contract) ----
    con.execute("""
        CREATE OR REPLACE TABLE fct_response AS
        WITH joined AS (
          SELECT s.*, a.creative, a.cohort_code, a.modality,
                 -- standalone (non-combined) file wins; deterministic
                 ROW_NUMBER() OVER (PARTITION BY s.archetype_id, s.question_key
                                    ORDER BY ends_with(s.run_id, 'x') ASC, s.run_id ASC) AS run_rank,
                 COUNT(*) OVER (PARTITION BY s.archetype_id, s.question_key) AS run_count
          FROM stg_response s JOIN dim_archetype a USING (archetype_id)
        )
        SELECT j.* EXCLUDE (run_rank, run_count),
               (run_rank = 1) AS is_primary_run,
               run_count AS n_runs_for_question,
               (SELECT min(o.option_code) FROM UNNEST(j.selected_options) AS t(o)
                WHERE o.option_code < 90) AS primary_code,
               d.scale_max
        FROM joined j
        LEFT JOIN (SELECT DISTINCT question_key, scale_max FROM dim_question_option) d
          USING (question_key)
    """)


def run_checks(con):
    """DQ01-DQ16 from Plan Section 8, plus the Gate 2/3/4 counts."""
    q = lambda sql: con.execute(sql).fetchone()[0]
    checks = []

    def check(cid, label, got, want):
        checks.append((cid, label, got, want, got == want))

    check("GATE1", "raw rows total", q(
        "SELECT (SELECT COUNT(*) FROM raw_read_s21)+(SELECT COUNT(*) FROM raw_read_s22)"
        "+(SELECT COUNT(*) FROM raw_read_s23)"), EXPECT["raw_rows"])
    check("DQ01", "fct_response rows", q("SELECT COUNT(*) FROM fct_response"),
          EXPECT["fact_rows"])
    check("DQ02", "distinct personas", q(
        "SELECT COUNT(DISTINCT archetype_id) FROM fct_response"), EXPECT["personas"])
    check("GATE2", "dim_archetype rows", q("SELECT COUNT(*) FROM dim_archetype"),
          EXPECT["personas"])
    check("DQ03", "distinct question_key", q(
        "SELECT COUNT(DISTINCT question_key) FROM fct_response"), EXPECT["questions"])
    check("GATE3", "dim_question rows", q("SELECT COUNT(*) FROM dim_question"),
          EXPECT["questions"])
    check("GATE3b", "distinct meta", q("SELECT COUNT(DISTINCT meta) FROM dim_question"),
          EXPECT["metas"])
    # question_key must be unique in dim_question or the fct join fans out
    check("DQ03b", "duplicate question_key in dim_question", q(
        "SELECT COUNT(*) FROM (SELECT question_key FROM dim_question "
        "GROUP BY 1 HAVING COUNT(*) > 1)"), 0)

    for cohort, n in COHORT_N.items():
        check("DQ04", f"personas in cohort {cohort}", q(
            f"SELECT COUNT(*) FROM dim_archetype WHERE cohort_code = '{cohort}'"), n)

    check("DQ05", "orphan facts (no dim_archetype)", q(
        "SELECT COUNT(*) FROM fct_response WHERE creative IS NULL"), 0)
    check("DQ06", "null age_band_banner", q(
        "SELECT COUNT(*) FROM dim_archetype WHERE age_band_banner IS NULL"), 0)
    check("DQ06b", "null creative", q(
        "SELECT COUNT(*) FROM dim_archetype WHERE creative IS NULL"), 0)
    check("DQ07", "imputed-age personas (drift alarm)", q(
        "SELECT count_if(age_band_is_imputed) FROM dim_archetype"), EXPECT["imputed_age"])
    check("DQ07b", "imputed-age raw file rows", q(
        "SELECT COUNT(*) FROM (SELECT archetype_age_range FROM raw_read_s21 "
        "UNION ALL SELECT archetype_age_range FROM raw_read_s22 "
        "UNION ALL SELECT archetype_age_range FROM raw_read_s23) "
        "WHERE archetype_age_range = '17-24'"), EXPECT["imputed_age_raw_rows"])
    check("DQ08", "type-1 rows missing qual_text", q(
        "SELECT COUNT(*) FROM fct_response WHERE q_type = '1' AND qual_text IS NULL"),
        EXPECT["missing_qual"])
    check("DQ09", "type-4/5 rows with no selected_options", q(
        "SELECT COUNT(*) FROM fct_response WHERE q_type IN ('4','5') "
        "AND len(selected_options) = 0"), 0)
    check("DQ10", "option_label retaining a leading code (D2)", q(
        "SELECT COUNT(*) FROM (SELECT unnest(selected_options) AS o FROM fct_response) "
        "WHERE regexp_matches(o.option_label, '^\\s*\\d+\\.')"), 0)
    # Scoped to single-select. Multi-selects legitimately reach scale_max 20
    # (SOCIAL has 17 options), so the plan's flat 2..12 bound fails 6 questions.
    check("DQ11", "single-select scale_max outside 1..6", q(
        "SELECT COUNT(*) FROM (SELECT DISTINCT question_key, scale_max "
        "FROM dim_question_option WHERE scale_max IS NOT NULL) s "
        "JOIN dim_question d USING (question_key) "
        "WHERE NOT d.is_multi_select AND (s.scale_max < 1 OR s.scale_max > 6)"), 0)
    check("DQ11b", "multi-select questions (box metrics suppressed)", q(
        "SELECT COUNT(*) FROM dim_question WHERE is_multi_select"), 9)
    check("DQ12", "verbatim count", q(
        "SELECT COUNT(*) FROM fct_response WHERE qual_text IS NOT NULL"),
        EXPECT["verbatims"])
    check("DQ13", "keys without exactly one primary run", q(
        "SELECT COUNT(*) FROM (SELECT archetype_id, question_key FROM fct_response "
        "GROUP BY 1,2 HAVING count_if(is_primary_run) <> 1)"), 0)
    check("DQ14", "income_high < income_low", q(
        "SELECT COUNT(*) FROM dim_archetype WHERE income_high_usd < income_low_usd"), 0)
    check("DQ15", "replicate rows (n_runs = 2)", q(
        "SELECT COUNT(*) FROM fct_response WHERE n_runs_for_question = 2"),
        EXPECT["replicate_rows"])
    check("DQ15b", "replicate keys", q(
        "SELECT COUNT(*) FROM (SELECT archetype_id, question_key FROM fct_response "
        "GROUP BY 1,2 HAVING COUNT(*) = 2)"), EXPECT["replicate_keys"])
    check("DQ16", "dim_run rows", q("SELECT COUNT(*) FROM dim_run"), EXPECT["runs"])
    check("DQ16b", "dim_run SUM(n_rows)", q("SELECT SUM(n_rows) FROM dim_run"),
          EXPECT["raw_rows"])

    # Gate 4 identity: single-run rows + replicate rows = total
    check("GATE4", "distinct (persona, question) keys", q(
        "SELECT COUNT(*) FROM (SELECT DISTINCT archetype_id, question_key "
        "FROM fct_response)"), EXPECT["distinct_keys"])
    check("GATE4b", "primary rows", q(
        "SELECT count_if(is_primary_run) FROM fct_response"), EXPECT["primary_rows"])
    return checks


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.isdir(src):
        sys.exit(f"source folder not found: {src}")

    con = duckdb.connect()
    print(f"Source: {src}")
    print("Building transform chain in DuckDB (raw -> staging -> curated) ...\n")
    build(con, src)
    checks = run_checks(con)

    width = max(len(label) for _, label, _, _, _ in checks)
    failed = 0
    for cid, label, got, want, passed in checks:
        if not passed:
            failed += 1
        status = "ok  " if passed else "FAIL"
        print(f"  {status}  {cid:<7} {label:<{width}}  got={got:<8} want={want}")

    print()
    if failed:
        print(f"{failed} of {len(checks)} checks FAILED - fix before loading to BigQuery.")
        return 1
    print(f"All {len(checks)} checks passed. Transform contract validated against source.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
