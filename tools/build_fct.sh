#!/usr/bin/env bash
#
# Build fct_response + v_response_metrics and check Gate 4.
#
# Gate 4 is the real finish line for the shaping half of Phase 1. Every value
# below was computed directly from the 12 source CSVs before this SQL was
# written, so a mismatch is a pipeline bug and never a wrong expectation.
#
#   40,178 rows / 398 personas / 91 questions
#   36,218 distinct (persona, question) keys == 36,218 primary rows
#    7,920 rows belonging to a replicated key
#
#   identity: 32,258 single-run + 7,920 replicate = 40,178
#
# Usage:
#     ./tools/build_fct.sh
#     ./tools/build_fct.sh --dry-run

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "${PROJECT_ID:-}" || -z "${DS_STG:-}" || -z "${DS_CUR:-}" ]]; then
  if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
  else
    echo "ERROR: config not in the environment and ./config.env not found." >&2
    exit 1
  fi
fi
: "${PROJECT_ID:?PROJECT_ID resolved empty}"
: "${DS_STG:?DS_STG resolved empty}"
: "${DS_CUR:?DS_CUR resolved empty}"

SCRIPTS=(30_fct_response 31_v_response_metrics)

for s in "${SCRIPTS[@]}"; do
  [[ -f "sql/${s}.sql" ]] || { echo "ERROR: sql/${s}.sql not found." >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for s in "${SCRIPTS[@]}"; do
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_STG}|${DS_STG}|g" \
      -e "s|\${DS_CUR}|${DS_CUR}|g" \
      "sql/${s}.sql" > "$WORK/${s}.sql"
  if grep -q '\${' "$WORK/${s}.sql"; then
    echo "ERROR: unsubstituted placeholder in ${s}:" >&2
    grep -n '\${' "$WORK/${s}.sql" >&2
    exit 1
  fi
done

echo "Project : $PROJECT_ID"
echo "Curated : $DS_CUR"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  for s in "${SCRIPTS[@]}"; do
    echo "===== sql/${s}.sql (resolved) ====="; cat "$WORK/${s}.sql"; echo
  done
  echo "Dry run — nothing executed."
  exit 0
fi

for s in "${SCRIPTS[@]}"; do
  echo "Running ${s} ..."
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet < "$WORK/${s}.sql"
done

# --- Gate 4 ---------------------------------------------------------------

checks_sql="
WITH
f AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.fct_response\`),
m AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.v_response_metrics\`)
SELECT check_name, actual, expected, (actual = expected) AS ok
FROM UNNEST([
  -- the six headline numbers
  STRUCT('G4-01 fct_response rows'        AS check_name, (SELECT COUNT(*) FROM f)                                                    AS actual, 40178 AS expected),
  STRUCT('G4-02 distinct personas',       (SELECT COUNT(DISTINCT archetype_id) FROM f),                                                        398),
  STRUCT('G4-03 distinct questions',      (SELECT COUNT(DISTINCT question_key) FROM f),                                                         91),
  STRUCT('G4-04 distinct persona-question',(SELECT COUNT(DISTINCT FORMAT('%s|%s', archetype_id, question_key)) FROM f),                       36218),
  STRUCT('G4-05 primary rows',            (SELECT COUNTIF(is_primary_run) FROM f),                                                           36218),
  STRUCT('G4-06 replicate rows',          (SELECT COUNTIF(n_runs_for_question = 2) FROM f),                                                    7920),
  -- structural invariants
  STRUCT('G4-07 runs per key > 2',        (SELECT COUNTIF(n_runs_for_question > 2) FROM f),                                                       0),
  STRUCT('G4-08 orphan facts (no dim)',   (SELECT COUNTIF(creative IS NULL OR cohort_code IS NULL) FROM f),                                      0),
  STRUCT('G4-09 distinct run_id',         (SELECT COUNT(DISTINCT run_id) FROM f),                                                               12),
  STRUCT('G4-10 one primary per key',     (SELECT COUNT(*) FROM (
                                             SELECT archetype_id, question_key FROM f WHERE is_primary_run
                                             GROUP BY 1,2 HAVING COUNT(*) != 1)),                                                                0),
  -- parsed measures
  STRUCT('G4-11 primary_code NULL',       (SELECT COUNTIF(primary_code IS NULL) FROM f),                                                      5587),
  STRUCT('G4-12 scale_max NULL',          (SELECT COUNTIF(scale_max IS NULL) FROM f),                                                         5170),
  STRUCT('G4-13 sentinel leaked into pc', (SELECT COUNTIF(primary_code >= 90) FROM f),                                                           0),
  -- the metrics view
  STRUCT('G4-14 is_tb TRUE',              (SELECT COUNTIF(is_tb) FROM m),                                                                    13451),
  STRUCT('G4-15 is_t2b TRUE',             (SELECT COUNTIF(is_t2b) FROM m),                                                                   22475),
  STRUCT('G4-16 is_bot TRUE',             (SELECT COUNTIF(is_bot) FROM m),                                                                    7573),
  STRUCT('G4-17 is_b2b TRUE',             (SELECT COUNTIF(is_b2b) FROM m),                                                                   14085),
  -- primary-run logic actually works: POSTINT is once per persona
  STRUCT('G4-18 POSTINT primary rows',    (SELECT COUNTIF(is_primary_run AND meta = 'POSTINT') FROM f),                                         398)
])
ORDER BY check_name
"

echo
echo "===== GATE 4 ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
echo "===== identity check ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT
  COUNTIF(n_runs_for_question = 1) AS single_run_rows,
  COUNTIF(n_runs_for_question = 2) AS replicate_rows,
  COUNT(*)                         AS total
FROM \`${PROJECT_ID}.${DS_CUR}.fct_response\`
"
echo "expected: 32258 + 7920 = 40178"

echo
if [[ "$fails" == "0" ]]; then
  echo "GATE 4 PASSED: 40,178 / 398 / 91 / 36,218 — all 18 assertions green."
  echo "Curated layer is complete. ff_30_marts can now be built."
else
  echo "GATE 4 FAILED: $fails assertion(s) red — see the ok column above." >&2
  exit 1
fi
