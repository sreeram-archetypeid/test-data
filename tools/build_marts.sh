#!/usr/bin/env bash
#
# Build ff_30_marts: dim_archetype_cuts + mart_banner_read.
#
# This is the presentation layer. It reads only ff_20_curated, and every query
# carries WHERE is_primary_run -- the replicated section 2.1 questions
# double-count 198 personas otherwise.
#
# The mart emits BOTH bases so switching needs no recompute:
#   base_kind = 'qre'         the routing the questionnaire defines (F11)
#   base_kind = 'unfiltered'  every answer the synthetic panel produced
#
# Rather than a fixed row count, this reports base sizes and asserts the two
# bases differ by exactly the amount the QRE routing accounts for. Cell counts
# depend on how many cuts each question qualifies for, so a hardcoded total
# would be brittle; the invariants below are the meaningful checks.
#
# Usage:
#     ./tools/build_marts.sh
#     ./tools/build_marts.sh --dry-run

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ -z "${PROJECT_ID:-}" || -z "${DS_CUR:-}" || -z "${DS_MART:-}" ]]; then
  if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
  else
    echo "ERROR: config not in the environment and ./config.env not found." >&2
    exit 1
  fi
fi
: "${PROJECT_ID:?PROJECT_ID resolved empty}"
: "${DS_CUR:?DS_CUR resolved empty}"
: "${DS_MART:?DS_MART resolved empty}"

SCRIPTS=(40_dim_archetype_cuts 41_mart_banner_read)
for s in "${SCRIPTS[@]}"; do
  [[ -f "sql/${s}.sql" ]] || { echo "ERROR: sql/${s}.sql not found." >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for s in "${SCRIPTS[@]}"; do
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_CUR}|${DS_CUR}|g" \
      -e "s|\${DS_MART}|${DS_MART}|g" \
      "sql/${s}.sql" > "$WORK/${s}.sql"
  if grep -q '\${' "$WORK/${s}.sql"; then
    echo "ERROR: unsubstituted placeholder in ${s}:" >&2
    grep -n '\${' "$WORK/${s}.sql" >&2
    exit 1
  fi
done

echo "Project : $PROJECT_ID"
echo "Marts   : $DS_MART"
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

# --- structural checks ----------------------------------------------------

checks_sql="
WITH
c AS (SELECT * FROM \`${PROJECT_ID}.${DS_MART}.dim_archetype_cuts\`),
b AS (SELECT * FROM \`${PROJECT_ID}.${DS_MART}.mart_banner_read\`)
SELECT check_name, actual, expected, (actual = expected) AS ok
FROM UNNEST([
  STRUCT('M-01 dim_archetype_cuts rows' AS check_name, (SELECT COUNT(*) FROM c)                                        AS actual, 398 AS expected),
  STRUCT('M-02 both base_kinds present',(SELECT COUNT(DISTINCT base_kind) FROM b),                                                  2),
  STRUCT('M-03 open_end excluded',      (SELECT COUNTIF(metric_kind = 'open_end') FROM b),                                          0),
  STRUCT('M-04 NULL cut_value',         (SELECT COUNTIF(cut_value IS NULL) FROM b),                                                 0),
  STRUCT('M-05 NULL metric value',      (SELECT COUNTIF(value IS NULL) FROM b),                                                     0),
  STRUCT('M-06 box metric off-ordinal', (SELECT COUNTIF(metric_name IN ('TB_PCT','T2B_PCT','BOT_PCT','B2B_PCT','MEAN')
                                           AND metric_kind != 'ordinal_scale') FROM b),                                             0),
  STRUCT('M-07 MEAN on ELEMENT1 [F9]',  (SELECT COUNTIF(meta = 'ELEMENT1' AND metric_name = 'MEAN') FROM b),                        0),
  STRUCT('M-08 T3B only on theatre item',(SELECT COUNTIF(metric_name = 'T3B_PCT'
                                            AND question_text NOT LIKE '%theater%') FROM b),                                        0),
  STRUCT('M-09 EXPOSURE_ORDER absent',  (SELECT COUNTIF(cut_name = 'EXPOSURE_ORDER') FROM b),                                       0),
  -- Total-cut base sizes are the numbers a banner reports. POSTINT is ungated,
  -- so both bases must give 398; DISLIKE is gated, so qre must give 372.
  STRUCT('M-10 POSTINT n, qre',         (SELECT CAST(MAX(value) AS INT64) FROM b
                                          WHERE meta='POSTINT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            398),
  STRUCT('M-11 DISLIKE n, qre [F11]',   (SELECT CAST(MAX(value) AS INT64) FROM b
                                          WHERE meta='DISLIKE' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            372),
  STRUCT('M-12 DISLIKE n, unfiltered',  (SELECT CAST(MAX(value) AS INT64) FROM b
                                          WHERE meta='DISLIKE' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='unfiltered'),                                     398),
  STRUCT('M-13 PARENT2 n, qre [F11]',   (SELECT CAST(MAX(value) AS INT64) FROM b
                                          WHERE meta='PARENT2' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            107),
  -- F10: the theatre item drops punch 6 from its own base
  STRUCT('M-14 theatre n < 398 [F10]',  (SELECT COUNTIF(value >= 398) FROM b
                                          WHERE meta='ACTIVITIES' AND question_text LIKE '%theater%'
                                            AND cut_name='TOTAL' AND metric_name='N'),                                             0)
])
ORDER BY check_name
"

echo
echo "===== MART STRUCTURAL CHECKS ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
echo "===== base sizes by question, TOTAL cut (qre vs unfiltered) ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT
  meta,
  CAST(MAX(IF(base_kind = 'qre',        value, NULL)) AS INT64) AS n_qre,
  CAST(MAX(IF(base_kind = 'unfiltered', value, NULL)) AS INT64) AS n_unfiltered
FROM \`${PROJECT_ID}.${DS_MART}.mart_banner_read\`
WHERE cut_name = 'TOTAL' AND metric_name = 'N'
GROUP BY meta
HAVING n_qre != n_unfiltered
ORDER BY n_unfiltered - n_qre DESC
"
echo "expect exactly the gated questions, and only those"

echo
echo "===== metrics emitted per metric_kind ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT metric_kind, STRING_AGG(DISTINCT metric_name ORDER BY metric_name) AS metrics
FROM \`${PROJECT_ID}.${DS_MART}.mart_banner_read\`
GROUP BY metric_kind ORDER BY metric_kind
"

echo
if [[ "$fails" == "0" ]]; then
  echo "MARTS BUILT: all 14 structural checks green."
  echo "EXPOSURE ORDER is absent by design -- nothing in the CSVs encodes it."
else
  echo "MART CHECKS FAILED: $fails red — see the ok column above." >&2
  exit 1
fi
