#!/usr/bin/env bash
# ============================================================================
# Run the whole ABR pipeline in BigQuery. Built for Cloud Shell, which already
# has bq, gsutil and python3.
#
#   ./bq/run_bq.sh -p my-project -b my-bucket -d /path/to/abr-repo
#   ./bq/run_bq.sh -p my-project -b my-bucket -d . --skip-upload      # data already staged
#   ./bq/run_bq.sh -p my-project -b my-bucket -d . --ai               # also run stages 11-14
#
# What it does, in order:
#   1. creates the datasets, the config tables and the UDFs
#   2. stages each export to GCS under a safe object name
#   3. CALLs sp_register_export + sp_unpivot per export
#   4. runs the curated, scale, theme, prose and mart scripts
#   5. runs the data-quality gate, which fails the run on a real problem
#
# Adding a new version later is steps 2-3 for that one file, then 4-5 again.
# Nothing here is destructive to other runs: each run_id is replaced in place.
# ============================================================================
set -euo pipefail

PROJECT="" ; BUCKET="" ; DATA="" ; PREFIX="abr/v1" ; LOCATION="US"
SKIP_UPLOAD=0 ; RUN_AI=0 ; DRY=0

usage () { sed -n '2,20p' "$0"; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT="$2"; shift 2 ;;
    -b|--bucket)  BUCKET="$2";  shift 2 ;;
    -d|--data)    DATA="$2";    shift 2 ;;
    --prefix)     PREFIX="$2";  shift 2 ;;
    --location)   LOCATION="$2"; shift 2 ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --ai)         RUN_AI=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    *) usage ;;
  esac
done
[[ -n "$PROJECT" && -n "$BUCKET" && -n "$DATA" ]] || usage

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_sql () {   # $1 = sql file
  local f="$1" out="$WORK/$(basename "$1")"
  sed -e "s/PROJECT_ID/$PROJECT/g" -e "s/BUCKET/$BUCKET/g" "$f" > "$out"
  printf '\n\033[1m>>> %s\033[0m\n' "$(basename "$f")"
  if [[ $DRY -eq 1 ]]; then head -3 "$out"; return; fi
  bq --project_id="$PROJECT" --location="$LOCATION" query \
     --use_legacy_sql=false --format=prettyjson < "$out" | head -40
}

call_sql () {  # $1 = a single statement
  printf '  %s\n' "$1"
  if [[ $DRY -eq 1 ]]; then return; fi
  bq --project_id="$PROJECT" --location="$LOCATION" query \
     --use_legacy_sql=false --format=none "$1"
}

# ---------------------------------------------------------------------------
# 0. work out what exports exist. Filenames carry study / instrument / panel /
#    build / date / run, so the registry is derived, not typed.
# ---------------------------------------------------------------------------
printf '\033[1m### discovering exports under %s\033[0m\n' "$DATA"
PYTHONPATH="$ROOT/tools" python3 "$ROOT/tools/00_discover.py" --data "$DATA" --out "$WORK"

# ---------------------------------------------------------------------------
# 1. contract first: datasets, config tables, UDFs. These are NOT re-run by a
#    later data load -- they change when you decide they change, in git.
# ---------------------------------------------------------------------------
run_sql "$HERE/00_setup.sql"
run_sql "$HERE/01_config.sql"
run_sql "$HERE/01b_udfs.sql"
run_sql "$HERE/02_load.sql"
run_sql "$HERE/03_unpivot.sql"

# ---------------------------------------------------------------------------
# 2 + 3. stage each export and land it. One table per run: the column count
#        differs per build, so a wildcard load would either fail on schema
#        mismatch or destroy the provenance a version comparison needs.
# ---------------------------------------------------------------------------
# Pipe-delimited. The source filenames contain spaces and an em-dash, so
# whitespace splitting mangles them; and tab is an IFS whitespace character in
# bash, so two adjacent tabs collapse and an empty export_date shifts every
# field after it by one.
python3 - "$WORK/registry.json" "$DATA" "$BUCKET" "$PREFIX" <<'PYPLAN' > "$WORK/plan.psv"
import json, sys
reg = json.load(open(sys.argv[1]))
data, bucket, prefix = sys.argv[2], sys.argv[3], sys.argv[4]
for e in reg["exports"]:
    src = f"{data}/{e['path']}"
    dst = f"gs://{bucket}/{prefix}/{e['run_id']}.csv"
    print("|".join(str(x) for x in [
        src, dst, e["run_id"], e["panel_code"], e["instrument"],
        e["build"], e["export_date"] or "", e["run_seq"]]))
PYPLAN

while IFS='|' read -r src dst run panel inst build dt seq; do
  [[ -n "$run" ]] || continue
  if [[ $SKIP_UPLOAD -eq 0 ]]; then
    printf '\033[1m### staging %s -> %s\033[0m\n' "$(basename "$src")" "$dst"
    [[ $DRY -eq 1 ]] || gsutil -q cp "$src" "$dst"
  fi
  printf '\033[1m### landing %s\033[0m\n' "$run"
  call_sql "CALL \`$PROJECT.abr_00_config.sp_register_export\`('$dst','$run','$panel','$inst','$build','$dt',$seq);"
  call_sql "CALL \`$PROJECT.abr_00_config.sp_unpivot\`('$run');"
done < "$WORK/plan.psv"

# ---------------------------------------------------------------------------
# 4. rebuild everything over whatever is registered.
# ---------------------------------------------------------------------------
run_sql "$HERE/10_run_all.sql"
call_sql "CALL \`$PROJECT.abr_00_config.sp_build_persona_dims\`();"
run_sql "$HERE/04_curated.sql"
run_sql "$HERE/05_scale_map.sql"
run_sql "$HERE/06_themes.sql"
run_sql "$HERE/07_prose.sql"
run_sql "$HERE/08_marts.sql"

# ---------------------------------------------------------------------------
# 5. the gate. Structural assertions, plus parity against the reference
#    implementation's measured numbers. A failure here stops the run.
# ---------------------------------------------------------------------------
run_sql "$HERE/09_dq.sql"

if [[ $RUN_AI -eq 1 ]]; then
  printf '\n\033[1m### AI stages -- these cost money. Read 11_ai_scale_rank.sql first.\033[0m\n'
  run_sql "$HERE/11_ai_scale_rank.sql"
  run_sql "$HERE/12_ai_verbatim_coding.sql"
  run_sql "$HERE/13_ai_embeddings_clusters.sql"
  run_sql "$HERE/14_ai_prose_score.sql"
fi

cat <<EOF

$(printf '\033[1mdone.\033[0m')  Start here, in this order:

  SELECT * FROM \`$PROJECT.abr_30_marts.dq_parity\` ORDER BY status DESC;
  SELECT * FROM \`$PROJECT.abr_20_curated.dim_question_review\`;          -- read before publishing
  SELECT * FROM \`$PROJECT.abr_30_marts.banner\` WHERE cut = 'total' ORDER BY latent_mean DESC;
  SELECT * FROM \`$PROJECT.abr_30_marts.theme_by_cut\` WHERE role = 'dislikes' AND cut = 'panel';
  SELECT * FROM \`$PROJECT.abr_30_marts.prose_metric_summary\` ORDER BY aat_agreement_pct;
  SELECT * FROM \`$PROJECT.abr_30_marts.mart_run_agreement\`;             -- run-to-run noise floor
  SELECT * FROM \`$PROJECT.abr_30_marts.mart_run_comparison\` WHERE verdict = 'material';

To add a version later:
  ./bq/run_bq.sh -p $PROJECT -b $BUCKET -d /path/with/the/new/file
EOF
