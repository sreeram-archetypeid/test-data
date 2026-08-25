#!/usr/bin/env bash
#
# Run the data-quality suite and report.
#
# Appends a timestamped run to ff_30_marts.dq_results, prints this run's rows,
# and exits non-zero if any assertion is red. Safe to run after every rebuild.
#
# Usage:
#     ./tools/run_dq.sh
#     ./tools/run_dq.sh --dry-run     # print resolved SQL, execute nothing
#     ./tools/run_dq.sh --history     # show pass counts per past run, no new run

set -euo pipefail

MODE=run
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --history) MODE=history ;;
  "") ;;
  *) echo "ERROR: unknown flag ${1}" >&2; exit 1 ;;
esac

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

if [[ "$MODE" == "history" ]]; then
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
  SELECT
    run_ts,
    COUNT(*)            AS assertions,
    COUNTIF(passed)     AS passed,
    COUNTIF(NOT passed) AS failed
  FROM \`${PROJECT_ID}.${DS_MART}.dq_results\`
  GROUP BY run_ts
  ORDER BY run_ts DESC
  LIMIT 20
  "
  exit 0
fi

[[ -f sql/90_dq.sql ]] || { echo "ERROR: sql/90_dq.sql not found." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
    -e "s|\${DS_CUR}|${DS_CUR}|g" \
    -e "s|\${DS_MART}|${DS_MART}|g" \
    sql/90_dq.sql > "$WORK/90_dq.sql"

if grep -q '\${' "$WORK/90_dq.sql"; then
  echo "ERROR: unsubstituted placeholder:" >&2
  grep -n '\${' "$WORK/90_dq.sql" >&2
  exit 1
fi

if [[ "$MODE" == "dry" ]]; then
  cat "$WORK/90_dq.sql"
  echo
  echo "Dry run — nothing executed."
  exit 0
fi

echo "Project : $PROJECT_ID"
echo "Results : ${DS_MART}.dq_results"
echo
echo "Running DQ suite ..."
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --quiet < "$WORK/90_dq.sql"

# --- report on the run just inserted --------------------------------------

latest="(SELECT MAX(run_ts) FROM \`${PROJECT_ID}.${DS_MART}.dq_results\`)"

echo
echo "===== DQ RESULTS ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT dq_id, assertion, actual, expected, passed
FROM \`${PROJECT_ID}.${DS_MART}.dq_results\`
WHERE run_ts = ${latest}
ORDER BY dq_id
"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet "
  SELECT COUNTIF(NOT passed)
  FROM \`${PROJECT_ID}.${DS_MART}.dq_results\`
  WHERE run_ts = ${latest}
  " | tail -n 1
)"

total="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet "
  SELECT COUNT(*)
  FROM \`${PROJECT_ID}.${DS_MART}.dq_results\`
  WHERE run_ts = ${latest}
  " | tail -n 1
)"

echo
if [[ "$fails" == "0" ]]; then
  echo "DQ SUITE PASSED: ${total}/${total} assertions green."
  echo
  echo "Phase 1 shaping is complete and regression-tested."
  echo "Run ./tools/run_dq.sh --history to see results across rebuilds."
else
  echo "DQ SUITE FAILED: ${fails} of ${total} assertions red — see passed=false above." >&2
  exit 1
fi
