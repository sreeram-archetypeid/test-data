#!/usr/bin/env bash
#
# Build the curated dimensions and check Gates 2, 2b and 3.
#
#   dim_archetype        398 rows   (Gate 2)
#   dim_run               12 rows   (Gate 2b)
#   dim_question          91 rows   (Gate 3)
#   dim_question_option  334 rows
#
# Every expected value below was measured from the source CSVs at the correct
# grain. Note in particular that the imputed-age count is 22 PERSONAS, not the
# 81 the plan doc states -- that 81 counts row-occurrences across the 12 wide
# files, and each persona appears in 3-4 of them (F2).
#
# Usage:
#     ./tools/build_curated_dims.sh
#     ./tools/build_curated_dims.sh --dry-run

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "${PROJECT_ID:-}" || -z "${DS_RAW:-}" || -z "${DS_STG:-}" || -z "${DS_CUR:-}" ]]; then
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
: "${DS_CUR:?DS_CUR resolved empty}"

SCRIPTS=(20_dim_archetype 21_dim_run 22_dim_question 23_dim_question_option)

for s in "${SCRIPTS[@]}"; do
  [[ -f "sql/${s}.sql" ]] || {
    echo "ERROR: sql/${s}.sql not found." >&2
    echo "       Generate dim_archetype first:  python3 tools/gen_dim_archetype.py" >&2
    exit 1
  }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for s in "${SCRIPTS[@]}"; do
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_RAW}|${DS_RAW}|g" \
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
    echo "===== sql/${s}.sql (resolved) ====="
    cat "$WORK/${s}.sql"
    echo
  done
  echo "Dry run — nothing executed."
  exit 0
fi

for s in "${SCRIPTS[@]}"; do
  echo "Running ${s} ..."
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet < "$WORK/${s}.sql"
done

# --- gates ----------------------------------------------------------------

checks_sql="
WITH
a AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.dim_archetype\`),
r AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.dim_run\`),
q AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.dim_question\`),
o AS (SELECT * FROM \`${PROJECT_ID}.${DS_CUR}.dim_question_option\`)
SELECT check_name, actual, expected, (actual = expected) AS ok
FROM UNNEST([
  -- Gate 2: dim_archetype
  STRUCT('G2-01 dim_archetype rows'      AS check_name, (SELECT COUNT(*) FROM a)                                       AS actual, 398 AS expected),
  STRUCT('G2-02 distinct archetype_id',  (SELECT COUNT(DISTINCT archetype_id) FROM a),                                            398),
  STRUCT('G2-03 age_band_banner NULL',   (SELECT COUNTIF(age_band_banner IS NULL) FROM a),                                          0),
  STRUCT('G2-04 creative NULL',          (SELECT COUNTIF(creative IS NULL) FROM a),                                                 0),
  STRUCT('G2-05 cohort_code NULL',       (SELECT COUNTIF(cohort_code IS NULL) FROM a),                                              0),
  STRUCT('G2-06 age imputed personas',   (SELECT COUNTIF(age_band_is_imputed) FROM a),                                             22),
  STRUCT('G2-07 age_exact populated',    (SELECT COUNTIF(age_exact IS NOT NULL) FROM a),                                           73),
  STRUCT('G2-08 gender_clean = Male',    (SELECT COUNTIF(gender_clean = 'Male') FROM a),                                          238),
  STRUCT('G2-09 gender_clean = Female',  (SELECT COUNTIF(gender_clean = 'Female') FROM a),                                        160),
  STRUCT('G2-10 gender_clean other',     (SELECT COUNTIF(gender_clean NOT IN ('Male','Female')) FROM a),                            0),
  STRUCT('G2-11 income_low NULL',        (SELECT COUNTIF(income_low_usd IS NULL) FROM a),                                           0),
  STRUCT('G2-12 income high < low',      (SELECT COUNTIF(income_high_usd < income_low_usd) FROM a),                                 0),
  STRUCT('G2-13 income open-ended',      (SELECT COUNTIF(income_is_open_ended) FROM a),                                             9),
  STRUCT('G2-14 nps_score NULL',         (SELECT COUNTIF(nps_score IS NULL) FROM a),                                                0),
  STRUCT('G2-15 nps Promoter',           (SELECT COUNTIF(nps_band = 'Promoter') FROM a),                                          148),
  STRUCT('G2-16 nps Passive',            (SELECT COUNTIF(nps_band = 'Passive') FROM a),                                           192),
  STRUCT('G2-17 nps Detractor',          (SELECT COUNTIF(nps_band = 'Detractor') FROM a),                                          58),
  STRUCT('G2-18 is_parent',              (SELECT COUNTIF(is_parent) FROM a),                                                      155),
  STRUCT('G2-19 cohort G.1',             (SELECT COUNTIF(cohort_code = 'G.1') FROM a),                                            100),
  STRUCT('G2-20 cohort G.2',             (SELECT COUNTIF(cohort_code = 'G.2') FROM a),                                            100),
  STRUCT('G2-21 cohort S.1',             (SELECT COUNTIF(cohort_code = 'S.1') FROM a),                                             98),
  STRUCT('G2-22 cohort S.2',             (SELECT COUNTIF(cohort_code = 'S.2') FROM a),                                            100),
  -- Gate 2b: dim_run
  STRUCT('G2b-01 dim_run rows',          (SELECT COUNT(*) FROM r),                                                                 12),
  STRUCT('G2b-02 sum n_rows',            (SELECT CAST(SUM(n_rows) AS INT64) FROM r),                                             1392),
  STRUCT('G2b-03 section_code NULL',     (SELECT COUNTIF(section_code IS NULL) FROM r),                                             0),
  STRUCT('G2b-04 combined files',        (SELECT COUNTIF(is_combined_file) FROM r),                                                 2),
  STRUCT('G2b-05 creative_of_file NULL', (SELECT COUNTIF(creative_of_file IS NULL) FROM r),                                         0),
  -- Gate 3: dim_question / dim_question_option
  STRUCT('G3-01 dim_question rows',      (SELECT COUNT(*) FROM q),                                                                 91),
  STRUCT('G3-02 distinct question_key',  (SELECT COUNT(DISTINCT question_key) FROM q),                                             91),
  STRUCT('G3-03 distinct meta',          (SELECT COUNT(DISTINCT meta) FROM q),                                                     36),
  STRUCT('G3-04 question_kind NULL',     (SELECT COUNTIF(question_kind IS NULL) FROM q),                                            0),
  STRUCT('G3-05 option rows',            (SELECT COUNT(*) FROM o),                                                                334),
  STRUCT('G3-06 sentinel options',       (SELECT COUNTIF(is_sentinel) FROM o),                                                      3),
  STRUCT('G3-07 scale_max NULL',         (SELECT COUNTIF(scale_max IS NULL) FROM o),                                                0),
  STRUCT('G3-08 options per code dup',   (SELECT COUNT(*) - COUNT(DISTINCT FORMAT('%s|%d', question_key, option_code)) FROM o),      0)
])
ORDER BY check_name
"

echo
echo "===== GATES 2 / 2b / 3 ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
echo "===== scale_max distribution (sanity, not a gate) ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT scale_max, COUNT(DISTINCT question_key) AS questions
FROM \`${PROJECT_ID}.${DS_CUR}.dim_question_option\`
GROUP BY scale_max ORDER BY scale_max
"

echo
if [[ "$fails" == "0" ]]; then
  echo "GATES 2 / 2b / 3 PASSED: 398 / 12 / 91 / 334, all 35 assertions green."
else
  echo "FAILED: $fails assertion(s) red — see the ok column above." >&2
  exit 1
fi
