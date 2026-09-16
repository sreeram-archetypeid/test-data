# Reminder: Cloud Run / container permissions

Skipped on 2026-09-16 because `sreeram@archetypeid.ai` got
`PERMISSION_DENIED` on `gcloud builds submit`.

## Why these roles are required
- Cloud Run Jobs only run a **container image** from Artifact Registry (or similar).
- Building/pushing that image needs:
  - `roles/cloudbuild.builds.editor` (or Admin) — submit Cloud Build
  - `roles/artifactregistry.writer` — push `drop-ingest:v1`
- UI “Create job” does **not** build an image; it only references one that already exists.

## Ask an Owner to grant
```bash
gcloud projects add-iam-policy-binding archetypeid-staging \
  --member="user:sreeram@archetypeid.ai" \
  --role="roles/cloudbuild.builds.editor"

gcloud projects add-iam-policy-binding archetypeid-staging \
  --member="user:sreeram@archetypeid.ai" \
  --role="roles/artifactregistry.writer"
```

Then from `pipeline/cloud_run_job`:
`gcloud builds submit --tag us-docker.pkg.dev/archetypeid-staging/survey-jobs/drop-ingest:v1 .`

Until then: use manual BQ load → `abr_drop002_to_canon.sql`.
