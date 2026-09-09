#!/usr/bin/env bash
# ABR-HTR wave: profile -> land -> scale -> themes -> prose -> analyse.
#
# Every stage is idempotent and fails loudly. Stage 2 reconciles against the
# counts stage 1 measured, so a changed export stops the run instead of
# quietly producing different numbers.
#
#   ./run_all.sh /path/to/abr-repo [outdir]
#
# Needs python3 and nothing else -- no pandas, no numpy, no network.
set -euo pipefail

DATA="${1:?usage: ./run_all.sh /path/to/abr-repo [outdir]}"
OUT="${2:-out}"
cd "$(dirname "$0")"
export PYTHONPATH="tools:${PYTHONPATH:-}"

step () { printf '\n\033[1m>>> %s\033[0m\n' "$1"; }

step "0/7 discover  -- find every export, parse its build, work out which pairs are comparable"
python3 tools/00_discover.py --data "$DATA" --out "$OUT"

step "1/7 profile   -- measure the exports, write the assessment and the reconciliation targets"
python3 tools/01_profile.py --data "$DATA" --out "$OUT" || true   # exits 1 only on FAIL findings

step "2/7 land      -- wide to long: dims, facts, and the BigQuery load artefacts"
python3 tools/02_land.py --data "$DATA" --out "$OUT"

step "3/7 scale map -- decide what top box means per question, flag what it cannot"
python3 tools/03_scale_map.py --out "$OUT"

step "4/7 themes    -- clean, code, cluster, and report incidence by question role"
python3 tools/04_semantic_themes.py --out "$OUT"

step "5/7 prose     -- score the prose-only headline metrics against the rubric"
python3 tools/05_prose_scale.py --out "$OUT"

step "6/7 analyse   -- banner, equated cross-panel read, replication, known answers, drivers"
python3 tools/06_analyze.py --data "$DATA" --out "$OUT"

printf '\n\033[1mdone.\033[0m outputs in %s/ -- start with %s/HTR_WAVE_ASSESSMENT.md\n' "$OUT" "$OUT"
printf 'review before publishing anything: %s/scale_review_queue.csv, %s/prose_unscored.csv, %s/uncoded_verbatims.csv\n' "$OUT" "$OUT" "$OUT"
