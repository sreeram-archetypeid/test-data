#!/usr/bin/env bash
# ============================================================================
# STAGE 2a — stage source files to GCS under safe names
#
# WHY rename: the source filenames contain an em-dash and spaces
# ("ABR-TSR_RETURN_v4_K_T1 — Results.csv"). Those survive gsutil but make every
# downstream URI quoting-sensitive and break shell loops in subtle ways. Slug
# the names once, here, and record the mapping so provenance is not lost.
#
# WHY CSV and not the XLSX: BigQuery cannot load .xlsx. The Drive CSV exports
# and the XLSX copies were verified to contain identical data (same row counts,
# same column lists, same archetype_id sets), so the CSV is the safe input.
#
# BEFORE RUNNING: put the two source CSVs in ./source/ named exactly:
#     source/ABR-TSR_RETURN_v4_K_T1 — Results.csv
#     source/ABR-TSR_RETURN_v4_K_T23 — Results.csv
# (Download from Drive folder 1V3Fd8vtoIwaG0CavZ87EpeixZTeEsKVk.)
# ============================================================================
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT=your-gcp-project-id}"
BUCKET="gs://${PROJECT}-abr-tsr-landing"
SRC="${SRC:-./source}"
STAMP="$(date -u +%Y%m%d)"

declare -A MAP=(
  ["ABR-TSR_RETURN_v4_K_T1 — Results.csv"]="abr_tsr_v4_k_t1.csv"
  ["ABR-TSR_RETURN_v4_K_T23 — Results.csv"]="abr_tsr_v4_k_t23.csv"
)

# Expected byte sizes — these are the files that were assessed. A size mismatch
# means you have a different export, and the Stage 3 checks will be measuring
# something other than what the assessment measured. Stop and reconcile.
declare -A EXPECT=( ["abr_tsr_v4_k_t1.csv"]=462524 ["abr_tsr_v4_k_t23.csv"]=1261620 )

for original in "${!MAP[@]}"; do
  slug="${MAP[$original]}"
  path="${SRC}/${original}"
  [[ -f "$path" ]] || { echo "MISSING: $path"; exit 1; }

  actual=$(stat -c%s "$path" 2>/dev/null || stat -f%z "$path")
  expect="${EXPECT[$slug]}"
  if [[ "$actual" != "$expect" ]]; then
    echo "WARNING: ${slug} is ${actual} bytes, expected ${expect}."
    echo "         This is a different export than the one assessed."
    read -r -p "         Continue anyway? [y/N] " ok
    [[ "$ok" == "y" ]] || exit 1
  fi

  echo "==> ${original}  ->  ${BUCKET}/raw/${STAMP}/${slug}"
  gcloud storage cp "$path" "${BUCKET}/raw/${STAMP}/${slug}"
done

# Provenance manifest: written alongside the data, not in a wiki.
{
  echo "staged_at_utc,${STAMP}"
  echo "original_filename,gcs_object,bytes"
  for original in "${!MAP[@]}"; do
    slug="${MAP[$original]}"
    echo "\"${original}\",raw/${STAMP}/${slug},${EXPECT[$slug]}"
  done
} > /tmp/abr_manifest_${STAMP}.csv
gcloud storage cp /tmp/abr_manifest_${STAMP}.csv "${BUCKET}/raw/${STAMP}/_manifest.csv"

echo
echo "==> staged. Set this in your SQL session before Stage 2b:"
echo "    STAMP = ${STAMP}"
