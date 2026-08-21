#!/usr/bin/env bash
#
# Land the raw layer and check Gate 1.
#
# Substitutes ${PROJECT_ID} / ${DS_RAW} / ${GCS_PREFIX} into the generated DDL in
# sql/01_raw_s2*.sql, runs each script, then asserts the row counts.
#
#     GATE 1   raw_read_s21 = 596   raw_read_s22 = 398   raw_read_s23 = 398
#              total = 1,392
#
# Also prints the 12 derived run_ids with their section_code, which is the
# check that the filename convention actually parses (see F4 in
# docs/PHASE1_RUNBOOK.md). A NULL section_code there means the staged object
# names are wrong, not that the SQL is.
#
# Usage:
#     ./tools/land_raw.sh            # run it
#     ./tools/land_raw.sh --dry-run  # print the resolved SQL, execute nothing
#
# Rendered SQL goes to a temp dir, so nothing generated lands in the repo.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# --- resolve config -------------------------------------------------------

if [[ -z "${PROJECT_ID:-}" || -z "${DS_RAW:-}" || -z "${GCS_PREFIX:-}" ]]; then
  if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
  else
    echo "ERROR: config not in the environment and ./config.env not found." >&2
    echo "       Run this from the repo root." >&2
    exit 1
  fi
fi
: "${PROJECT_ID:?PROJECT_ID resolved empty}"
: "${DS_RAW:?DS_RAW resolved empty}"
: "${GCS_PREFIX:?GCS_PREFIX resolved empty}"

FAMILIES=(s21 s22 s23)
declare -a EXPECTED=(596 398 398)
EXPECTED_TOTAL=1392

for fam in "${FAMILIES[@]}"; do
  [[ -f "sql/01_raw_${fam}.sql" ]] || {
    echo "ERROR: sql/01_raw_${fam}.sql not found." >&2
    echo "       Generate it first:  python3 tools/gen_raw_schema.py --all" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_RAW}|${DS_RAW}|g" \
      -e "s|\${GCS_PREFIX}|${GCS_PREFIX}|g" \
      "sql/01_raw_${1}.sql" > "$WORK/01_raw_${1}.sql"
}

# --- render ---------------------------------------------------------------

echo "Project : $PROJECT_ID"
echo "Dataset : $DS_RAW"
echo "Source  : $GCS_PREFIX"
echo

for fam in "${FAMILIES[@]}"; do
  render "$fam"
  # Any surviving placeholder means a variable was empty or misspelled.
  if grep -q '\${' "$WORK/01_raw_${fam}.sql"; then
    echo "ERROR: unsubstituted placeholder left in $fam DDL:" >&2
    grep -n '\${' "$WORK/01_raw_${fam}.sql" >&2
    exit 1
  fi
done

if [[ "$DRY_RUN" -eq 1 ]]; then
  for fam in "${FAMILIES[@]}"; do
    echo "===== sql/01_raw_${fam}.sql (resolved) ====="
    cat "$WORK/01_raw_${fam}.sql"
    echo
  done
  echo "Dry run — nothing executed."
  exit 0
fi

# --- execute --------------------------------------------------------------

for fam in "${FAMILIES[@]}"; do
  echo "Building ext_read_${fam} + raw_read_${fam} ..."
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet \
    < "$WORK/01_raw_${fam}.sql"
done

# --- Gate 1 ---------------------------------------------------------------

echo
echo "===== GATE 1 ====="

counts_sql="
SELECT 'raw_read_s21' AS tbl, COUNT(*) AS n FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s21\`
UNION ALL
SELECT 'raw_read_s22', COUNT(*) FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s22\`
UNION ALL
SELECT 'raw_read_s23', COUNT(*) FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s23\`
ORDER BY tbl
"

# Read into an array without mapfile, which is bash 4+ and absent on macOS.
rows=()
while IFS= read -r line; do
  [[ -n "$line" ]] && rows+=("$line")
done < <(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false \
           --format=csv --quiet "$counts_sql" | tail -n +2
)

fail=0
total=0
for i in "${!FAMILIES[@]}"; do
  row="${rows[$i]:-}"
  actual="${row##*,}"
  want="${EXPECTED[$i]}"
  total=$(( total + ${actual:-0} ))
  if [[ "$actual" == "$want" ]]; then
    printf '  %-14s %6s  (expected %s)  OK\n' "raw_read_${FAMILIES[$i]}" "$actual" "$want"
  else
    printf '  %-14s %6s  (expected %s)  *** MISMATCH ***\n' \
      "raw_read_${FAMILIES[$i]}" "${actual:-<none>}" "$want"
    fail=1
  fi
done

printf '  %-14s %6s  (expected %s)  %s\n' "TOTAL" "$total" "$EXPECTED_TOTAL" \
  "$([[ "$total" == "$EXPECTED_TOTAL" ]] && echo OK || echo '*** MISMATCH ***')"
[[ "$total" == "$EXPECTED_TOTAL" ]] || fail=1

# --- run_id / section_code derivation (F4 check) --------------------------

echo
echo "===== run_id -> section_code (expect 12 rows, no NULLs) ====="

runs_sql="
WITH all_files AS (
  SELECT _source_file FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s21\`
  UNION ALL SELECT _source_file FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s22\`
  UNION ALL SELECT _source_file FROM \`${PROJECT_ID}.${DS_RAW}.raw_read_s23\`
),
derived AS (
  SELECT REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv\$') AS run_id
  FROM all_files
)
SELECT
  run_id,
  REPLACE(REGEXP_EXTRACT(run_id, r's(2_\d)x?\$'), '_', '.') AS section_code,
  ENDS_WITH(run_id, 'x')                                    AS is_combined_file,
  COUNT(*)                                                  AS n_rows
FROM derived
GROUP BY run_id, section_code, is_combined_file
ORDER BY run_id
"

bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$runs_sql"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "GATE 1 PASSED: 596 / 398 / 398 = 1,392 rows landed."
else
  echo "GATE 1 FAILED — stop here and diagnose before shaping." >&2
  exit 1
fi
