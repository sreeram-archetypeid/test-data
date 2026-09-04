#!/usr/bin/env bash
#
# Build the reference tables and the cell-for-cell validation mart, then assert.
#
#   sql/44_ref_wtabs.sql       the human W-Tabs, joinable (cells, tables, crosswalk)
#   sql/50_mart_validation.sql ours vs theirs, one row per comparable cell
#
# The local path (tools/build_comparison_csv.py) stays the reproducible
# artifact: it runs from repo files with no credentials, so anyone can
# regenerate it byte-identically. This makes the same comparison queryable by
# people who are not running Python.
#
# Usage:
#     ./tools/validate_banners.sh
#     ./tools/validate_banners.sh --dry-run
#
# Needs GOOGLE_ACCESS_TOKEN. Uses tools/bq_query.py, so no bq CLI is required.
# The three reference CSVs must already be staged under $GCS_REF_PREFIX --
# see the staging note at the bottom of this file.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
: "${GOOGLE_ACCESS_TOKEN:?GOOGLE_ACCESS_TOKEN is unset — export it first}"

q() { python3 tools/bq_query.py --format tsv -e "$1" | tail -n +2; }

TMP_WH="$(mktemp)"
trap 'rm -f "$TMP_WH"' EXIT

# Measured after the build, never chosen to make a gate pass.
EXPECT_CELLS=99231           # ref_wtabs, one row per printed cell
EXPECT_TABLES=152            # ref_wtab_tables
EXPECT_CROSSWALK=340         # ref_wtab_crosswalk
EXPECT_PAIRS=37              # banner-column map, mirrors validate_local.PAIRS
EXPECT_VAL_QUESTIONS=74      # questions reaching the comparison

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would run, in order:"
  echo "  sql/44_ref_wtabs.sql"
  echo "  sql/50_mart_validation.sql"
  echo "Then assert: $EXPECT_CELLS cells / $EXPECT_TABLES tables /"
  echo "             $EXPECT_CROSSWALK crosswalk rows / $EXPECT_PAIRS column pairs /"
  echo "             $EXPECT_VAL_QUESTIONS questions, no SIGMA or NET rows,"
  echo "             and every dual-sourced cell agreeing."
  exit 0
fi

echo "==> sql/44_ref_wtabs.sql"
python3 tools/bq_query.py sql/44_ref_wtabs.sql

echo "==> Gate 1: the human study landed intact"
read -r cells tables xw < <(q '
SELECT
  (SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_CUR}.ref_wtabs`),
  (SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_CUR}.ref_wtab_tables`),
  (SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_CUR}.ref_wtab_crosswalk`)')
echo "    cells=$cells tables=$tables crosswalk=$xw"
[[ "$cells"  == "$EXPECT_CELLS"     ]] || { echo "GATE FAILED: expected $EXPECT_CELLS cells" >&2; exit 1; }
[[ "$tables" == "$EXPECT_TABLES"    ]] || { echo "GATE FAILED: expected $EXPECT_TABLES tables" >&2; exit 1; }
[[ "$xw"     == "$EXPECT_CROSSWALK" ]] || { echo "GATE FAILED: expected $EXPECT_CROSSWALK crosswalk rows" >&2; exit 1; }

echo "==> Gate 2: the banner-column map has not drifted from validate_local.PAIRS"
# The map is a literal inside sql/50. If someone edits PAIRS and not the SQL
# (or the reverse) the comparison silently loses or gains columns, so the two
# counts are checked against each other rather than against a constant alone.
py_pairs="$(python3 - <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("vl", "tools/validate_local.py")
vl = importlib.util.module_from_spec(spec); sys.argv = ["x"]
spec.loader.exec_module(vl)
print(len(vl.PAIRS))
PY
)"
sql_pairs="$(grep -c "STRUCT('.*' AS wtab_group" sql/50_mart_validation.sql)"
echo "    validate_local.PAIRS=$py_pairs   sql/50 literal=$sql_pairs"
[[ "$py_pairs" == "$sql_pairs" ]] || { echo "GATE FAILED: PAIRS and sql/50 disagree" >&2; exit 1; }
[[ "$py_pairs" == "$EXPECT_PAIRS" ]] || { echo "GATE FAILED: expected $EXPECT_PAIRS pairs" >&2; exit 1; }

echo "==> sql/50_mart_validation.sql"
python3 tools/bq_query.py sql/50_mart_validation.sql

echo "==> Gate 3: no SIGMA or NET rows reached the comparison"
# A SIGMA is a column total and a NET is a roll-up of the rows beneath it.
# Neither is an answer option. Joining a NET on an option label matches nothing,
# and a generator that then writes 0% produces a confident wrong number -- the
# exact defect fixed in tools/build_wtabs_style_csv.py. Excluded at source in
# sql/50; asserted here so it stays that way.
leaked="$(q '
SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_MART}.mart_validation` v
JOIN `${PROJECT_ID}.${DS_CUR}.ref_wtabs` r
  ON r.table_no = v.table_no AND r.metric_label = v.option_label
WHERE r.is_sigma OR r.is_net')"
echo "    SIGMA/NET rows in the comparison: $leaked"
[[ "$leaked" == "0" ]] || { echo "GATE FAILED: $leaked SIGMA/NET rows leaked in" >&2; exit 1; }

echo "==> Gate 4: cells with two human sources agree"
# ACTIVITIES 'play video games' x 'Every week' is printed both in that item's
# per_item table and in the 'Every week' summary table. That duplication is a
# free consistency check on THEIR file, so it is kept rather than deduplicated.
read -r dup agree < <(q '
WITH d AS (
  SELECT COUNT(DISTINCT ROUND(theirs_pct, 4)) AS variants
  FROM `${PROJECT_ID}.${DS_MART}.mart_validation`
  GROUP BY question_key, cut_name, cut_value, option_label
  HAVING COUNT(*) > 1
)
SELECT COUNT(*), COUNTIF(variants = 1) FROM d')
echo "    dual-sourced cells=$dup  agreeing=$agree"
[[ "$dup" == "$agree" ]] || { echo "GATE FAILED: $((dup - agree)) dual-sourced cells disagree" >&2; exit 1; }

echo "==> Gate 5: question coverage"
qs="$(q 'SELECT COUNT(DISTINCT question_key) FROM `${PROJECT_ID}.${DS_MART}.mart_validation`')"
echo "    questions=$qs"
[[ "$qs" == "$EXPECT_VAL_QUESTIONS" ]] || { echo "GATE FAILED: expected $EXPECT_VAL_QUESTIONS questions" >&2; exit 1; }

echo "==> Gate 6: the warehouse agrees with the credential-free local build, CELL BY CELL"
# The strongest check in the project. tools/build_comparison_csv.py computes the
# same comparison in Python from the raw CSVs, sharing no code with this SQL. If
# the two disagree on a value, one of them is wrong -- and that is exactly how
# the missing base rules were found: the two disagreed on 196 cells (144
# POLORIENT, 52 ACTIVITIES) because the local tool was not applying the
# questionnaire's routing, so its denominators were inflated. Their numbers
# matched all along; only ours were wrong.
if [[ ! -f out/banner_comparison.csv ]]; then
  echo "    out/banner_comparison.csv absent — running the local build first"
  python3 tools/build_comparison_csv.py >/dev/null
fi
python3 tools/bq_query.py --format tsv -e '
SELECT question_key, cut_name, cut_value, option_label,
       ROUND(ours_pct, 6) AS ours, ROUND(theirs_pct, 6) AS theirs
FROM `${PROJECT_ID}.${DS_MART}.mart_validation`
GROUP BY 1, 2, 3, 4, 5, 6' > "$TMP_WH"

python3 - "$TMP_WH" <<'PY'
import csv, sys, collections
wh = {}
for r in csv.DictReader(open(sys.argv[1], encoding="utf-8"), delimiter="\t"):
    wh[(r["question_key"], r["cut_name"], r["cut_value"],
        r["option_label"].strip().lower())] = (float(r["ours"]), float(r["theirs"]))
lo, meta = {}, {}
for r in csv.DictReader(open("out/banner_comparison.csv", encoding="utf-8")):
    if not r.get("ours_pct") or not r.get("theirs_pct"):
        continue
    k = (r["question_key"], r["cut_name"], r["cut_value"],
         (r["option_label"] or "").strip().lower())
    try:
        lo[k] = (float(r["ours_pct"]), float(r["theirs_pct"]))
    except ValueError:
        continue
    meta[k] = r["meta"]

common = set(wh) & set(lo)
bad_o = [k for k in common if abs(wh[k][0] - lo[k][0]) > 0.0005]
bad_t = [k for k in common if abs(wh[k][1] - lo[k][1]) > 0.0005]
print(f"    overlapping cells {len(common):,}")
print(f"    OURS   disagreeing: {len(bad_o)}")
print(f"    THEIRS disagreeing: {len(bad_t)}")
for label, bad in (("ours", bad_o), ("theirs", bad_t)):
    if bad:
        for m, c in collections.Counter(meta[k] for k in bad).most_common(5):
            print(f"       {label}: {c} in {m}")
if bad_o or bad_t:
    raise SystemExit("GATE FAILED: the two implementations disagree on a value")
if len(common) < 10000:
    raise SystemExit(f"GATE FAILED: only {len(common)} cells overlap; expected ~10,090")
PY

echo
echo "GATE PASSED: mart_validation rebuilt, all gates green."
echo
echo "Staging note: sql/44 reads three CSVs from \$GCS_REF_PREFIX. Two are"
echo "build outputs of tools/extract_wtabs.py and one is committed:"
echo "    python3 tools/extract_wtabs.py"
echo "    for f in wtabs_cells wtabs_tables wtabs_crosswalk; do"
echo "      GCS_PREFIX=\"\$GCS_REF_PREFIX\" python3 tools/gcs_helper.py cp ref/\$f.csv \$f.csv"
echo "    done"
