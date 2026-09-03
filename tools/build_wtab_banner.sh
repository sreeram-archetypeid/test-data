#!/usr/bin/env bash
#
# Build the W-Tabs-shaped banner: dim_cuts_wtab (sql/42) then mart_banner_wtab
# (sql/43), with the gates the other builders carry.
#
# Why this exists: these were the only two SQL files in the repo with no runner.
# Every other tools/build_*.sh shells out to `bq`, which cannot be installed in
# the web sandbox, so these two were executed ad-hoc and there was nothing to
# commit. That is also how sql/43's "never pool ELEMENT2" rule went unenforced
# for so long -- its header said the assertion lived in this file, and this file
# did not exist.
#
# Order matters: sql/43 joins dim_cuts_wtab, so sql/42 must land first.
#
# Usage:
#     ./tools/build_wtab_banner.sh
#     ./tools/build_wtab_banner.sh --dry-run
#
# Needs GOOGLE_ACCESS_TOKEN. Uses tools/bq_query.py, which needs no bq CLI.

set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

: "${GOOGLE_ACCESS_TOKEN:?GOOGLE_ACCESS_TOKEN is unset — export it first}"

q() { python3 tools/bq_query.py --format tsv -e "$1" | tail -n +2; }

# Every expectation below was MEASURED from the built tables, never guessed --
# the repo's standing rule. A red gate means the pipeline changed.
EXPECT_CUT_ROWS=6238
EXPECT_CUT_PERSONAS=398
EXPECT_CUT_FAMILIES=13
EXPECT_MART_QUESTIONS=81

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Would run, in order:"
  echo "  sql/42_dim_cuts_wtab.sql"
  echo "  sql/43_mart_banner_wtab.sql"
  echo "Then assert: cuts ${EXPECT_CUT_ROWS} rows / ${EXPECT_CUT_PERSONAS} personas /"
  echo "             ${EXPECT_CUT_FAMILIES} families, mart ${EXPECT_MART_QUESTIONS} questions,"
  echo "             0 pooled-qre ELEMENT2 rows, and SIGMA = 1 on every column."
  exit 0
fi

echo "==> sql/42_dim_cuts_wtab.sql"
python3 tools/bq_query.py sql/42_dim_cuts_wtab.sql

echo "==> Gate 1: cut membership"
read -r rows personas families < <(q '
SELECT COUNT(*), COUNT(DISTINCT archetype_id), COUNT(DISTINCT cut_name)
FROM `${PROJECT_ID}.${DS_MART}.dim_cuts_wtab`')
echo "    rows=$rows personas=$personas families=$families"
[[ "$rows" == "$EXPECT_CUT_ROWS" ]] || { echo "GATE FAILED: expected $EXPECT_CUT_ROWS rows" >&2; exit 1; }
[[ "$personas" == "$EXPECT_CUT_PERSONAS" ]] || { echo "GATE FAILED: expected $EXPECT_CUT_PERSONAS personas" >&2; exit 1; }
[[ "$families" == "$EXPECT_CUT_FAMILIES" ]] || { echo "GATE FAILED: expected $EXPECT_CUT_FAMILIES families" >&2; exit 1; }

echo "==> sql/43_mart_banner_wtab.sql"
python3 tools/bq_query.py sql/43_mart_banner_wtab.sql

echo "==> Gate 2: ELEMENT2 is never pooled under the QRE base"
# F14. The gate leaves Goyer at 171 of 200 and Sheridan at 176 of 198, so a
# pooled qre figure averages two differently-gated bases and understates Goyer.
# The unfiltered scope is fine and is deliberately not counted here.
bad="$(q '
SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_MART}.mart_banner_wtab`
WHERE meta = "ELEMENT2" AND creative = "(pooled)" AND base_kind = "qre"')"
echo "    pooled-qre ELEMENT2 rows=$bad"
[[ "$bad" == "0" ]] || { echo "GATE FAILED: $bad pooled-qre ELEMENT2 rows — see sql/43 scoped_cr" >&2; exit 1; }

echo "==> Gate 3: question coverage"
qs="$(q 'SELECT COUNT(DISTINCT question_key) FROM `${PROJECT_ID}.${DS_MART}.mart_banner_wtab`')"
echo "    questions=$qs"
[[ "$qs" == "$EXPECT_MART_QUESTIONS" ]] || { echo "GATE FAILED: expected $EXPECT_MART_QUESTIONS questions" >&2; exit 1; }

echo "==> Gate 4: SIGMA — every single-punch column sums to 100%"
# The strongest structural check available: for a categorical or ordinal
# question every persona has exactly one selected option, so the per-option
# percentages within a column must sum to 1. A base or join defect breaks this
# immediately, which is how the duplicate banner_col bug was caught upstream.
off="$(q '
SELECT COUNT(*) FROM (
  SELECT ROUND(SUM(value), 4) AS sigma
  FROM `${PROJECT_ID}.${DS_MART}.mart_banner_wtab`
  WHERE metric_name = "PCT_OF_BASE"
  GROUP BY base_kind, creative, question_key, cut_name, cut_value
) WHERE sigma != 1.0')"
echo "    columns not summing to 1.0000: $off"
[[ "$off" == "0" ]] || { echo "GATE FAILED: $off columns do not sum to 100%" >&2; exit 1; }

rows="$(q 'SELECT COUNT(*) FROM `${PROJECT_ID}.${DS_MART}.mart_banner_wtab`')"
echo
echo "GATE PASSED: mart_banner_wtab rebuilt, $rows rows, all 4 gates green."
