#!/usr/bin/env bash
#
# Build fct_response + v_response_metrics and check Gate 4.
#
# G4-14..17 assert the UNGATED primary_code rules on fct_response, not the
# view: v_response_metrics gates its flags on metric_kind from Step 14, so
# reading them here would couple this gate to a later step. The gated counts
# are asserted in tools/build_metric_model.sh.
#
# G4-16/17 use the F8-corrected battery scale_max (6,967 / 13,245). Before that
# fix they were 7,573 / 14,085, which counted 606 and 840 rows as bottom box on
# questions whose offered scale was longer than the codes respondents used.
#
# Gate 6 (G6-*) checks the QRE base flag: 676 rows excluded at ROW grain, and
# the rule table dim_qre_base must agree with the CASE that implements it.
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

SCRIPTS=(24_dim_qre_base 30_fct_response 31_v_response_metrics)

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
b AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.dim_qre_base\`)
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
  -- ungated primary_code rules (the gated flags are checked in build_metric_model.sh)
  STRUCT('G4-14 primary_code = 1',        (SELECT COUNTIF(primary_code = 1) FROM f),                                                       13451),
  STRUCT('G4-15 primary_code IN (1,2)',   (SELECT COUNTIF(primary_code IN (1, 2)) FROM f),                                                  22475),
  STRUCT('G4-16 primary_code = scale_max',(SELECT COUNTIF(primary_code = scale_max) FROM f),                                                 6967),
  STRUCT('G4-17 primary_code IN (max-1,max)', (SELECT COUNTIF(primary_code IN (scale_max - 1, scale_max)) FROM f),                          13245),
  -- primary-run logic actually works: POSTINT is once per persona
  STRUCT('G4-18 POSTINT primary rows',    (SELECT COUNTIF(is_primary_run AND meta = 'POSTINT') FROM f),                                         398),
  -- Gate 6: the QRE base (F11). Row-grain, not persona-grain -- PARENT2 is in
  -- section 2.1, whose personas carry two replicate runs.
  STRUCT('G6-01 dim_qre_base rows',       (SELECT COUNT(*) FROM b),                                                                              9),
  STRUCT('G6-02 is_in_qre_base NULL',     (SELECT COUNTIF(is_in_qre_base IS NULL) FROM f),                                                       0),
  STRUCT('G6-03 excluded rows total',     (SELECT COUNTIF(NOT is_in_qre_base) FROM f),                                                         676),
  STRUCT('G6-04 in-base rows total',      (SELECT COUNTIF(is_in_qre_base) FROM f),                                                            39502),
  STRUCT('G6-05 ungated question excluded',(SELECT COUNTIF(NOT is_in_qre_base AND meta NOT IN
                                             (SELECT meta FROM b)) FROM f),                                                                      0),
  -- rule table and implementation must agree, per question
  STRUCT('G6-06 rule/impl disagreement',  (SELECT COUNT(*) FROM (
                                             SELECT b.meta FROM b JOIN (
                                               SELECT meta, COUNTIF(NOT is_in_qre_base) AS excl FROM f GROUP BY meta
                                             ) AS x USING (meta)
                                             WHERE x.excl != b.expected_excluded_rows)),                                                         0),
  -- persona-grain base sizes, the numbers a banner actually reports
  STRUCT('G6-07 base personas PARENT2',   (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='PARENT2'   AND is_in_qre_base),              107),
  STRUCT('G6-08 base personas POLORIENT', (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='POLORIENT' AND is_in_qre_base),              338),
  STRUCT('G6-09 base personas LIKE',      (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='LIKE'      AND is_in_qre_base),              355),
  STRUCT('G6-10 base personas DISLIKE',   (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='DISLIKE'   AND is_in_qre_base),              372),
  STRUCT('G6-11 base personas URG2',      (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='URG2'      AND is_in_qre_base),              347),
  STRUCT('G6-12 base personas PRELIKE1',  (SELECT COUNT(DISTINCT archetype_id) FROM f WHERE meta='PRELIKE1'  AND is_in_qre_base),              393)
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
  echo "GATES 4 + 6 PASSED: 40,178 rows, 39,502 in the QRE base, all 30 assertions green."
  echo "Curated layer is complete. ff_30_marts can now be built."
else
  echo "GATE 4 FAILED: $fails assertion(s) red — see the ok column above." >&2
  exit 1
fi
