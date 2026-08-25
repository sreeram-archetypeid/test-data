#!/usr/bin/env bash
#
# Phase 1 close-out: rebuild dim_question with metric_kind, gate the box-metric
# view, build fct_response_option, and check Gate 5.
#
# Why this step exists
# --------------------
# v_response_metrics previously applied ordinal box metrics to all 80 closed
# questions. 11 are not ordinal: 9 unordered multi-select pick-lists (CHARDES,
# STORYDES, SOCIAL, ELEMENT2, SEEWITH, PLATFORM, AUD2, GENREFIT, Screener 1)
# and 2 single-option formalities (INTRO2, Screener 2). On those, option_code is
# a category id rather than a rank, so "top box" is not a quantity.
#
# After the gate, is_tb TRUE drops from 13,451 to 11,414 -- those 2,037 rows
# were being counted as top box on questions where the phrase has no meaning.
# They are now NULL rather than wrong.
#
# This step also carries the F8 fix: dim_question_option now derives scale_max
# from the BATTERY maximum (max non-sentinel code across the meta) rather than
# the codes respondents used. That corrects 8 questions and drops is_bot
# 6,566 -> 5,960 and is_b2b 12,840 -> 12,000. is_tb and is_t2b are unchanged,
# so every TOP BOX cut was always right.
#
# fct_response_option is the grain those 9 questions actually need: one row per
# selected option, so "what share said Terry Bogard is 'determined'" becomes
# answerable. The plan doc names this table in its architecture and never
# defines it.
#
# Usage:
#     ./tools/build_metric_model.sh
#     ./tools/build_metric_model.sh --dry-run

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

# Order matters: dim_question must carry metric_kind before the view reads it.
# Order is a real dependency chain, not a preference:
#   23  dim_question_option   -- carries the F8 battery scale_max
#   22  dim_question          -- carries metric_kind
#   30  fct_response          -- READS scale_max from 23, so it must be rebuilt
#                                after it or it keeps the stale value
#   32  fct_response_option   -- unnests fct_response
#   31  v_response_metrics    -- reads metric_kind from 22 and scale_max via 30
SCRIPTS=(23_dim_question_option 22_dim_question 30_fct_response 32_fct_response_option 31_v_response_metrics)

for s in "${SCRIPTS[@]}"; do
  [[ -f "sql/${s}.sql" ]] || { echo "ERROR: sql/${s}.sql not found." >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Substitute placeholders and refuse to continue if any survived.
resolve() {  # resolve <src> <dst>
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_STG}|${DS_STG}|g" \
      -e "s|\${DS_CUR}|${DS_CUR}|g" \
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

# --- Gate 5 ---------------------------------------------------------------
#
# Written through a SINGLE-QUOTED heredoc and then the same sed pass as the
# committed sql/ files -- never as a double-quoted bash string, where a literal
# like '$75K' expands as positional parameter $7 and aborts under `set -u`.
# Writing it before the --dry-run exit is what makes --dry-run exercise it.

cat > "$WORK/_gates.in.sql" <<'GATESQL'
WITH
q  AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_question`),
m  AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.v_response_metrics`),
o  AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.fct_response_option`),
qo AS (SELECT * FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`),
sc AS (SELECT DISTINCT question_key, scale_max FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`)
SELECT check_name, actual, expected, (actual = expected) AS ok
FROM UNNEST([
  -- dim_question + classification
  STRUCT('G5-01 dim_question rows'          AS check_name, (SELECT COUNT(*) FROM q)                                                    AS actual, 91 AS expected),
  STRUCT('G5-02 metric_kind NULL',          (SELECT COUNTIF(metric_kind IS NULL) FROM q),                                                        0),
  STRUCT('G5-03 kind ordinal_scale',        (SELECT COUNTIF(metric_kind = 'ordinal_scale') FROM q),                                             54),
  STRUCT('G5-04 kind multi_select',         (SELECT COUNTIF(metric_kind = 'multi_select') FROM q),                                                9),
  STRUCT('G5-05 kind single_option',        (SELECT COUNTIF(metric_kind = 'single_option') FROM q),                                               2),
  STRUCT('G5-06 kind numeric_rating',       (SELECT COUNTIF(metric_kind = 'numeric_rating') FROM q),                                              1),
  STRUCT('G5-07 kind open_end',             (SELECT COUNTIF(metric_kind = 'open_end') FROM q),                                                   10),
  -- the classification is right, not just the counts
  STRUCT('G5-08 CHARDES is multi_select',   (SELECT COUNTIF(meta = 'CHARDES' AND metric_kind = 'multi_select') FROM q),                           1),
  STRUCT('G5-08b kind categorical [F9]',    (SELECT COUNTIF(metric_kind = 'categorical') FROM q),                                              15),
  STRUCT('G5-08c ELEMENT1 all categorical', (SELECT COUNTIF(meta = 'ELEMENT1' AND metric_kind != 'categorical') FROM q),                         0),
  STRUCT('G5-09 ordinal scale_max out of {2,3,4,6}',
                                            (SELECT COUNT(*) FROM q JOIN sc USING (question_key)
                                             WHERE q.metric_kind = 'ordinal_scale' AND sc.scale_max NOT IN (2,3,4,6)),                            0),
  -- the gate actually applied
  STRUCT('G5-10 box flags non-NULL rows',   (SELECT COUNTIF(is_tb IS NOT NULL) FROM m),                                                      24264),
  STRUCT('G5-11 box flags NULL rows',       (SELECT COUNTIF(is_tb IS NULL) FROM m),                                                         15914),
  STRUCT('G5-12 is_tb on non-ordinal',      (SELECT COUNTIF(metric_kind != 'ordinal_scale' AND is_tb IS NOT NULL) FROM m),                        0),
  STRUCT('G5-13 is_tb TRUE (gated)',        (SELECT COUNTIF(is_tb) FROM m),                                                                   7399),
  STRUCT('G5-14 is_t2b TRUE (gated)',       (SELECT COUNTIF(is_t2b) FROM m),                                                                 15306),
  STRUCT('G5-15 is_bot TRUE (gated)',       (SELECT COUNTIF(is_bot) FROM m),                                                                  4193),
  STRUCT('G5-16 is_b2b TRUE (gated)',       (SELECT COUNTIF(is_b2b) FROM m),                                                                 10045),
  -- fct_response_option
  STRUCT('G5-17 fct_response_option rows',  (SELECT COUNT(*) FROM o),                                                                        39490),
  STRUCT('G5-18 sentinel option rows',      (SELECT COUNTIF(is_sentinel) FROM o),                                                              419),
  STRUCT('G5-19 option_code NULL',          (SELECT COUNTIF(option_code IS NULL) FROM o),                                                        0),
  STRUCT('G5-20 distinct personas in option',(SELECT COUNT(DISTINCT archetype_id) FROM o),                                                     398),
  -- F8: battery-level scale_max
  STRUCT('G5-21 dim_question_option rows',  (SELECT COUNT(*) FROM qo),                                                                        334),
  STRUCT('G5-22 battery-corrected questions',(SELECT COUNT(DISTINCT question_key) FROM qo WHERE scale_max_source = 'battery'),                   8),
  STRUCT('G5-23 scale_max below battery max',(SELECT COUNT(*) FROM qo WHERE scale_max < observed_max),                                           0),
  STRUCT('G5-24 scale_max NULL',            (SELECT COUNTIF(scale_max IS NULL) FROM qo),                                                        0)
])
ORDER BY check_name
GATESQL

resolve "$WORK/_gates.in.sql" "$WORK/_gates.sql"
checks_sql="$(cat "$WORK/_gates.sql")"

echo "Project : $PROJECT_ID"
echo "Curated : $DS_CUR"
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  for s in "${SCRIPTS[@]}"; do
    echo "===== sql/${s}.sql (resolved) ====="; cat "$WORK/${s}.sql"; echo
  done
  echo "===== gate SQL (resolved) ====="; cat "$WORK/_gates.sql"; echo
  echo "Dry run — nothing executed."
  exit 0
fi

for s in "${SCRIPTS[@]}"; do
  echo "Running ${s} ..."
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet < "$WORK/${s}.sql"
done

echo
echo "===== GATE 5 ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
echo "===== metric_kind map (sanity, not a gate) ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT metric_kind, COUNT(*) AS questions, STRING_AGG(DISTINCT meta ORDER BY meta LIMIT 12) AS sample_metas
FROM \`${PROJECT_ID}.${DS_CUR}.dim_question\`
GROUP BY metric_kind ORDER BY questions DESC
"

echo
if [[ "$fails" == "0" ]]; then
  echo "GATE 5 PASSED: 54/15/9/2/1/10 classified, 39,490 option rows, box flags gated."
  echo "Marts can now be built with the correct metric per question."
else
  echo "GATE 5 FAILED: $fails assertion(s) red — see the ok column above." >&2
  exit 1
fi
