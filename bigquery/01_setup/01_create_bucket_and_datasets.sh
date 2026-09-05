#!/usr/bin/env bash
# ============================================================================
# STAGE 1a — GCS bucket + BigQuery datasets
#
# WHY a separate bucket: the Fatal Fury study already occupies its own landing
# space. Mixing studies in one bucket makes lifecycle rules and access grants
# ambiguous, and makes "which file fed which table" unanswerable six months
# from now. One bucket per study, versioning on, is the cheap insurance.
#
# WHY six datasets instead of one: each layer has a different contract and a
# different blast radius. You can drop and rebuild abr_30_semantic (expensive
# but reproducible) without touching abr_10_raw (cheap but irreplaceable if the
# source Drive files move). Layer numbers sort in run order in the console.
#
# WHY region US everywhere: BigQuery datasets, the Vertex connection and the
# remote models must be region-compatible. A mismatch is the commonest cause of
# a confusing AI.* failure. Change REGION below only if you change it in ALL
# files, including 02_create_connection_and_models.sql.
# ============================================================================
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT=your-gcp-project-id}"
REGION="US"                 # BigQuery location (multi-region)
CONN_REGION="us"            # connection location, lowercase
BUCKET="gs://${PROJECT}-abr-tsr-landing"

echo "==> project=${PROJECT} region=${REGION} bucket=${BUCKET}"

# ---- bucket -----------------------------------------------------------------
# Uniform bucket-level access: IAM only, no per-object ACLs. Versioning: a
# re-upload of a same-named file cannot silently destroy the original load.
gcloud storage buckets create "${BUCKET}" \
  --project="${PROJECT}" \
  --location="${REGION}" \
  --uniform-bucket-level-access \
  --public-access-prevention || echo "    bucket exists, continuing"

gcloud storage buckets update "${BUCKET}" --versioning

# ---- datasets ---------------------------------------------------------------
# 00_ext      external tables pointing at GCS (no data copied)
# 10_raw      loaded, every column STRING, one table per source file
# 20_curated  typed dims + the long fact table; the analysis contract
# 30_semantic AI outputs: scale ranking, coded verbatims, embeddings
# 40_marts    banner-ready aggregates with base flags and CIs
# 90_ops      DQ check results, run log, prompt versions
for DS in abr_00_ext abr_10_raw abr_20_curated abr_30_semantic abr_40_marts abr_90_ops; do
  bq --project_id="${PROJECT}" --location="${REGION}" mk -d \
     --description "ABR-TSR Air Bud Returns trailer study — layer ${DS##abr_}" \
     "${DS}" 2>/dev/null && echo "    created ${DS}" || echo "    ${DS} exists"
done

echo
echo "==> NEXT: upload the source files"
echo "    bash 02_load/03_stage_to_gcs.sh"
