#!/usr/bin/env bash
#
# Unpivot raw wide -> long and build ff_10_staging.stg_response.
#
# Gates:
#   per section   stg_response_s21 = 11,920   s22 = 13,930   s23 = 14,328
#   combined      stg_response     = 40,178
#   plus 9 parse assertions, every threshold measured from the source CSVs.
#
# The two that matter most:
#   sentinel tokens (option_code >= 90) must be 419. If this comes back 0, the
#   option code is being read from the position prefix rather than the code
#   prefix (F5), and BOT/B2B on Screener 1, PLATFORM and SOCIAL are wrong.
#   labels still prefixed 'N.' must be 0, which catches a D2 regression.
#
# Usage:
#     ./tools/shape_staging.sh
#     ./tools/shape_staging.sh --dry-run

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "${PROJECT_ID:-}" || -z "${DS_RAW:-}" || -z "${DS_STG:-}" ]]; then
  if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
  else
    echo "ERROR: config not in the environment and ./config.env not found." >&2
    exit 1
  fi
fi
: "${PROJECT_ID:?PROJECT_ID resolved empty}"
: "${DS_RAW:?DS_RAW resolved empty}"
: "${DS_STG:?DS_STG resolved empty}"

FAMILIES=(s21 s22 s23)
SCRIPTS=(10_stg_response_s21 10_stg_response_s22 10_stg_response_s23 11_stg_response)

for s in "${SCRIPTS[@]}"; do
  [[ -f "sql/${s}.sql" ]] || {
    echo "ERROR: sql/${s}.sql not found." >&2
    echo "       Generate the unpivots first:  python3 tools/gen_unpivot.py --all" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Substitute placeholders and refuse to continue if any survived.
resolve() {  # resolve <src> <dst>
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_RAW}|${DS_RAW}|g" \
      -e "s|\${DS_STG}|${DS_STG}|g" \
      "$1" > "$2"
  if grep -q '\${' "$2"; then
    echo "ERROR: unsubstituted placeholder in $1:" >&2
    grep -n '\${' "$2" >&2
    exit 1
  fi
}

for s in "${SCRIPTS[@]}"; do
  resolve "sql/${s}.sql" "$WORK/${s}.sql"
done

# --- gate SQL -------------------------------------------------------------
#
# Written through SINGLE-QUOTED heredocs and then the same sed pass as the
# committed sql/ files -- never as double-quoted bash strings, where a literal
# like '$75K' expands as positional parameter $7 and aborts under `set -u`.
# Writing them before the --dry-run exit is what makes --dry-run exercise them.

cat > "$WORK/_per_section.in.sql" <<'GATESQL'
SELECT 'stg_response_s21' AS tbl, COUNT(*) AS n FROM `${PROJECT_ID}.${DS_STG}.stg_response_s21`
UNION ALL SELECT 'stg_response_s22', COUNT(*) FROM `${PROJECT_ID}.${DS_STG}.stg_response_s22`
UNION ALL SELECT 'stg_response_s23', COUNT(*) FROM `${PROJECT_ID}.${DS_STG}.stg_response_s23`
ORDER BY tbl
GATESQL

cat > "$WORK/_gates.in.sql" <<'GATESQL'
WITH
resp AS (SELECT * FROM `${PROJECT_ID}.${DS_STG}.stg_response`),
opts AS (SELECT o.* FROM resp, UNNEST(resp.selected_options) AS o)
SELECT check_name, actual, expected, (actual = expected) AS ok
FROM UNNEST([
  STRUCT('01 stg_response rows'        AS check_name, (SELECT COUNT(*) FROM resp)                                  AS actual, 40178 AS expected),
  STRUCT('02 distinct archetype_id',   (SELECT COUNT(DISTINCT archetype_id) FROM resp),                                       398),
  STRUCT('03 distinct question_key',   (SELECT COUNT(DISTINCT question_key) FROM resp),                                        91),
  STRUCT('04 distinct meta',           (SELECT COUNT(DISTINCT meta) FROM resp),                                                36),
  STRUCT('05 distinct run_id',         (SELECT COUNT(DISTINCT run_id) FROM resp),                                              12),
  STRUCT('06 option tokens',           (SELECT COUNT(*) FROM opts),                                                         39490),
  STRUCT('07 sentinel tokens >=90',    (SELECT COUNTIF(option_code >= 90) FROM opts),                                        419),
  STRUCT('08 option_code NULL',        (SELECT COUNTIF(option_code IS NULL) FROM opts),                                        0),
  STRUCT('09 labels still N. prefixed',(SELECT COUNTIF(REGEXP_CONTAINS(option_label, r'^[0-9]+\.')) FROM opts),                 0),
  STRUCT('10 verbatims',               (SELECT COUNTIF(qual_text IS NOT NULL) FROM resp),                                  17301),
  STRUCT('11 numeric ratings',         (SELECT COUNTIF(rating_value IS NOT NULL) FROM resp),                                  596)
])
ORDER BY check_name
GATESQL

resolve "$WORK/_per_section.in.sql" "$WORK/_per_section.sql"
resolve "$WORK/_gates.in.sql"       "$WORK/_gates.sql"
per_section_sql="$(cat "$WORK/_per_section.sql")"
checks_sql="$(cat "$WORK/_gates.sql")"

echo "Project : $PROJECT_ID"
echo "Raw     : $DS_RAW"
echo "Staging : $DS_STG"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Resolved SQL in $WORK:"
  ls -1 "$WORK"
  echo
  cat "$WORK/11_stg_response.sql"
  echo "===== gate SQL (resolved) ====="
  cat "$WORK/_per_section.sql"; echo
  cat "$WORK/_gates.sql"
  echo "Dry run — nothing executed."
  trap - EXIT
  echo "(left in $WORK)"
  exit 0
fi

# --- run ------------------------------------------------------------------

for s in "${SCRIPTS[@]}"; do
  echo "Running ${s} ..."
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet < "$WORK/${s}.sql"
done

# --- per-section gate -----------------------------------------------------

echo
echo "===== per-section row counts ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$per_section_sql"
echo "expected: 11920 / 13930 / 14328"

# --- parse assertions -----------------------------------------------------

echo
echo "===== staging assertions ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
if [[ "$fails" == "0" ]]; then
  echo "STAGING GATE PASSED: 40,178 rows, all 11 assertions green."
else
  echo "STAGING GATE FAILED: $fails assertion(s) red — see the ok column above." >&2
  exit 1
fi
