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
# 81 of the 91 questions reach the mart; the 10 open_end ones are tabulated in
# Phase 4. That is why the base-size checks name POLORIENT (338 vs 398) and
# ELEMENT2 (347 vs 398): they are the only two of the nine QRE-routed questions
# that are not open_end. M-22 records the absence of the other seven so it reads
# as a decision rather than an omission.
#
# GRAIN: this mart is keyed by creative, so cut_name='TOTAL' is per creative --
# Goyer 200 personas, Sheridan 198 -- and every base-size check SUMs the two.
# M-21 asserts that grain directly, so a whole-study number can never again be
# compared against a single creative's row without something going red.
#
# M-06/07/08 are not paperwork. Box metrics, MEAN and T3B are each gated on
# metric_kind in the SQL because COUNTIF over a NULL flag returns 0, not NULL --
# ungated, the mart would publish a confident 0.0% top box on every pick-list.
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

# Substitute placeholders and refuse to continue if any survived.
resolve() {  # resolve <src> <dst>
  sed -e "s|\${PROJECT_ID}|${PROJECT_ID}|g" \
      -e "s|\${DS_CUR}|${DS_CUR}|g" \
      -e "s|\${DS_MART}|${DS_MART}|g" \
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

# --- structural checks ----------------------------------------------------
#
# Written through a SINGLE-QUOTED heredoc and then the same sed pass as the
# committed sql/ files -- never as a double-quoted bash string, where a literal
# like '$75K' expands as positional parameter $7 and aborts under `set -u`.
# Writing it before the --dry-run exit is what makes --dry-run exercise it.

cat > "$WORK/_gates.in.sql" <<'GATESQL'
WITH
c AS (SELECT * FROM `${PROJECT_ID}.${DS_MART}.dim_archetype_cuts`),
b AS (SELECT * FROM `${PROJECT_ID}.${DS_MART}.mart_banner_read`)
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
  STRUCT('M-10 questions in mart',      (SELECT COUNT(DISTINCT question_key) FROM b),                                             81),
  -- Total-cut base sizes are the numbers a banner reports. Measured from the
  -- CSVs first; the parse that produced them reproduces Gate 4 exactly.
  --
  -- SUM, NOT MAX. This mart is grained by creative, so cut_name='TOTAL' means
  -- "no demographic cut, WITHIN one creative" -- two rows per question, Goyer
  -- (200 personas) and Sheridan (198). MAX silently returned whichever creative
  -- happened to be larger, which is not even consistently the same one: on
  -- ELEMENT2 the qre base is Goyer 171 vs Sheridan 176. Summing the two is the
  -- whole-study base these expectations were written against.
  --
  -- POLORIENT and ELEMENT2 are the ONLY two routed questions that reach this
  -- mart. The other seven are open_end (M-22), so the qre-vs-unfiltered gap is
  -- visible here on these two alone.
  STRUCT('M-11 POSTINT n, qre',         (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='POSTINT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            398),
  STRUCT('M-12 POSTINT n, Goyer',       (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='POSTINT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'
                                            AND creative='Goyer'),                                                               200),
  STRUCT('M-13 POSTINT n, Sheridan',    (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='POSTINT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'
                                            AND creative='Sheridan'),                                                            198),
  STRUCT('M-14 POLORIENT n, qre [F11]', (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='POLORIENT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            338),
  STRUCT('M-15 POLORIENT n, unfiltered',(SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='POLORIENT' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='unfiltered'),                                     398),
  STRUCT('M-16 ELEMENT2 n, qre [F11]',  (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='ELEMENT2' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'),                                            347),
  -- ELEMENT2's gate (URG1 IN 2,3,4) excludes 29 Goyer personas but only 22
  -- Sheridan ones: more Goyer readers wanted to see it right away, so fewer were
  -- asked what held them back. A real difference between the creatives, pinned
  -- here so a pooled total cannot hide it.
  STRUCT('M-17 ELEMENT2 n, Goyer [F11]',(SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='ELEMENT2' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'
                                            AND creative='Goyer'),                                                               171),
  STRUCT('M-18 ELEMENT2 n, Sheridan',   (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='ELEMENT2' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='qre'
                                            AND creative='Sheridan'),                                                            176),
  STRUCT('M-19 ELEMENT2 n, unfiltered', (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='ELEMENT2' AND cut_name='TOTAL'
                                            AND metric_name='N' AND base_kind='unfiltered'),                                     398),
  -- F10: the theatre item drops punch 6 ('Never', 2 personas) from its own base
  STRUCT('M-20 theatre n, qre [F10]',   (SELECT CAST(SUM(value) AS INT64) FROM b
                                          WHERE meta='ACTIVITIES' AND question_text LIKE '%theater%'
                                            AND cut_name='TOTAL' AND metric_name='N'
                                            AND base_kind='qre'),                                                                396),
  -- THE GRAIN GUARD. Every (base_kind, question, TOTAL, N) group must hold
  -- exactly two rows, one per creative. This is the check whose absence let the
  -- MAX mistake above show up as six unexplained near-halves instead of being
  -- named on the first run. It also fails loudly if the mart is ever pooled
  -- across creatives or gains a third.
  STRUCT('M-21 TOTAL cut not 2 creatives',(SELECT COUNT(*) FROM (
                                            SELECT base_kind, question_key FROM b
                                            WHERE cut_name='TOTAL' AND metric_name='N'
                                            GROUP BY 1,2 HAVING COUNT(DISTINCT creative) != 2)),                                    0),
  -- Records WHY the other seven routed questions are absent, so a reader does
  -- not read their absence as an oversight. They are open_end -> Phase 4.
  STRUCT('M-22 gated open-ends absent', (SELECT COUNTIF(meta IN
                                           ('PARENT2','LIKE','DISLIKE','URG2','PRELIKE1','PRELIKE2')) FROM b),                     0)
])
ORDER BY check_name
GATESQL

resolve "$WORK/_gates.in.sql" "$WORK/_gates.sql"
checks_sql="$(cat "$WORK/_gates.sql")"

echo "Project : $PROJECT_ID"
echo "Marts   : $DS_MART"
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
echo "===== MART STRUCTURAL CHECKS ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "$checks_sql"

fails="$(
  bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=csv --quiet \
    "SELECT COUNTIF(NOT ok) FROM ($checks_sql)" | tail -n 1
)"

echo
echo "===== base sizes by question, TOTAL cut (qre vs unfiltered) ====="
# SUM across the two creatives, not MAX -- see the note on M-11. Reporting MAX
# here printed one creative's base (POLORIENT 170) while the assertions expected
# the whole study (338), which made the wrong numbers look self-consistent.
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT
  meta,
  CAST(SUM(IF(base_kind = 'qre',        value, 0)) AS INT64) AS n_qre,
  CAST(SUM(IF(base_kind = 'unfiltered', value, 0)) AS INT64) AS n_unfiltered
FROM \`${PROJECT_ID}.${DS_MART}.mart_banner_read\`
WHERE cut_name = 'TOTAL' AND metric_name = 'N'
GROUP BY meta
HAVING n_qre != n_unfiltered
ORDER BY n_unfiltered - n_qre DESC
"
echo "expect POLORIENT 338 | 398 and ELEMENT2 347 | 398 -- those two and no others"

echo
echo "===== metrics emitted per metric_kind ====="
bq query --project_id="$PROJECT_ID" --use_legacy_sql=false --format=pretty --quiet "
SELECT metric_kind, STRING_AGG(DISTINCT metric_name ORDER BY metric_name) AS metrics
FROM \`${PROJECT_ID}.${DS_MART}.mart_banner_read\`
GROUP BY metric_kind ORDER BY metric_kind
"

echo
if [[ "$fails" == "0" ]]; then
  echo "MARTS BUILT: all 22 structural checks green."
  echo "EXPOSURE ORDER is absent by design -- nothing in the CSVs encodes it."
else
  echo "MART CHECKS FAILED: $fails red — see the ok column above." >&2
  exit 1
fi
