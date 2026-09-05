-- ============================================================================
-- STAGE 1b — Vertex AI connection + remote models
--
-- WHAT: a BigQuery "connection" is a service identity that lets SQL call
-- Vertex AI. The remote MODEL objects are thin pointers to a Vertex endpoint;
-- they hold no weights and cost nothing to create.
--
-- WHY two models: text generation and embedding are different endpoints. One
-- model object cannot serve both.
--
-- ORDER OF OPERATIONS (the part that trips everyone up):
--   1. Create the connection FIRST, in the shell, not here:
--
--        bq mk --connection --location=us --project_id=$PROJECT \
--              --connection_type=CLOUD_RESOURCE abr_vertex
--
--   2. Read back its service account:
--
--        bq show --connection --location=us --project_id=$PROJECT abr_vertex
--
--   3. Grant that SA permission to call Vertex. Without this the models create
--      fine and every AI.* query fails at run time with a permission error
--      that does not mention the connection:
--
--        gcloud projects add-iam-policy-binding $PROJECT \
--          --member="serviceAccount:<SA_FROM_STEP_2>" \
--          --role="roles/aiplatform.user"
--
--   4. Wait ~60s for the grant to propagate, THEN run this file.
--
-- Replace PROJECT_ID below before running (BigQuery DDL cannot parameterise
-- an object name).
-- ============================================================================

-- Text generation: used by AI.GENERATE_TABLE for scale ranking (Stage 5a) and
-- verbatim coding (Stage 5c), and by AI.GENERATE for cluster labels (5e).
CREATE OR REPLACE MODEL `PROJECT_ID.abr_30_semantic.gemini_text`
REMOTE WITH CONNECTION `PROJECT_ID.us.abr_vertex`
OPTIONS (ENDPOINT = 'gemini-2.5-flash');
-- ENDPOINT note: use a current Gemini endpoint available in your project.
-- Flash is the right default here — the tasks are short, highly constrained and
-- run at temperature 0, so a larger model buys little. If Stage 5b's stability
-- check fails, switching to a Pro endpoint is the first thing to try.

-- Embeddings: used by ML.GENERATE_EMBEDDING in Stage 5d.
CREATE OR REPLACE MODEL `PROJECT_ID.abr_30_semantic.text_embedding`
REMOTE WITH CONNECTION `PROJECT_ID.us.abr_vertex`
OPTIONS (ENDPOINT = 'text-embedding-005');

-- ---------------------------------------------------------------------------
-- Prompt version registry.
--
-- WHY this table exists: a prompt edit silently re-codes the entire study and
-- the output looks identical. Every AI stage writes the prompt hash it used
-- into its output table and joins back here. If a number moves between runs,
-- this is how you find out whether the prompt moved with it.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `PROJECT_ID.abr_90_ops.prompt_registry` (
  prompt_id     STRING  NOT NULL,   -- e.g. 'scale_rank_v1'
  stage         STRING  NOT NULL,   -- '5a' | '5c' | '5e'
  prompt_text   STRING  NOT NULL,   -- the literal prompt, for diffing
  prompt_sha256 STRING  NOT NULL,   -- TO_HEX(SHA256(prompt_text))
  model_endpoint STRING,
  temperature   FLOAT64,
  registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
  notes         STRING
);

-- Run-log: one row per stage execution, so the pipeline is auditable.
CREATE TABLE IF NOT EXISTS `PROJECT_ID.abr_90_ops.run_log` (
  stage       STRING,
  object_name STRING,
  row_count   INT64,
  started_at  TIMESTAMP,
  finished_at TIMESTAMP,
  notes       STRING
);
