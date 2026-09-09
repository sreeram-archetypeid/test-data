-- ============================================================================
-- ABR concept-test pipeline -- stage 0: datasets, connection, models
-- ============================================================================
-- Everything in bq/ runs in BigQuery. No Python, no local files, no laptop.
-- Substitute PROJECT_ID (and BUCKET in 02) before running, or use
-- bq/run_bq.sh which does it for you.
--
-- ONE REGION for datasets, connection and models. A region mismatch is the
-- commonest cause of an AI.* function failing with a confusing error, and it
-- fails at stage 5, long after you have stopped thinking about regions.
--
-- Layer roles, and the rule that keeps them honest:
--   abr_00_config    the analysis contract: lexicon, codeframe, roles, rubrics
--   abr_01_raw       exact copy of source, every column STRING, immutable
--   abr_10_staging   long grain, typed and parsed
--   abr_20_curated   dims and facts -- what analysis binds to
--   abr_30_marts     banner, comparisons, drivers
--   abr_40_semantic  embeddings, clusters, AI passes
-- Nothing queries abr_01_raw except abr_10_staging.
-- ============================================================================

-- Datasets. Run once. Safe to re-run.
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_00_config`  OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_01_raw`     OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_10_staging` OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_20_curated` OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_30_marts`   OPTIONS (location = 'US');
CREATE SCHEMA IF NOT EXISTS `PROJECT_ID.abr_40_semantic` OPTIONS (location = 'US');

-- ----------------------------------------------------------------------------
-- The Vertex connection cannot be created in SQL. Run this once in Cloud Shell,
-- then grant the connection's service account roles/aiplatform.user:
--
--   bq mk --connection --location=US --project_id=PROJECT_ID \
--         --connection_type=CLOUD_RESOURCE vertex
--   SA=$(bq show --format=prettyjson --connection PROJECT_ID.US.vertex \
--        | python3 -c 'import json,sys;print(json.load(sys.stdin)["cloudResource"]["serviceAccountId"])')
--   gcloud projects add-iam-policy-binding PROJECT_ID \
--         --member="serviceAccount:$SA" --role="roles/aiplatform.user"
--
-- The AI stages (bq/11_*) need this. Stages 1-9 do not: everything through the
-- banner is deterministic SQL, which is the point -- the model is asked only
-- about the residue the rules cannot settle.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE MODEL `PROJECT_ID.abr_40_semantic.gemini_flash`
REMOTE WITH CONNECTION `PROJECT_ID.US.vertex`
OPTIONS (endpoint = 'gemini-2.0-flash');

CREATE OR REPLACE MODEL `PROJECT_ID.abr_40_semantic.text_embedding`
REMOTE WITH CONNECTION `PROJECT_ID.US.vertex`
OPTIONS (endpoint = 'text-embedding-005');
