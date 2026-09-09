-- ============================================================================
-- Stage 13 (optional): emergent themes -- clustering with NO codeframe.
-- ============================================================================
-- The codeframe is a hypothesis. This is the check on it: cluster the corpus
-- without it, then look at which clusters the frame barely covers. In the prior
-- wave that is how the audio/sensory complaint surfaced -- volunteered by 40%+
-- of personas with no closed-end option anywhere able to capture it.
--
-- task_type = 'CLUSTERING' is NOT the default and it materially changes the
-- space. Do not omit it.
-- ============================================================================

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.verbatim_embedding` AS
SELECT doc_id, run_id, archetype_id, panel, meta, qual_clean,
       ml_generate_embedding_result AS embedding
FROM ML.GENERATE_EMBEDDING(
  MODEL `PROJECT_ID.abr_40_semantic.text_embedding`,
  (SELECT doc_id, run_id, archetype_id, panel, meta, qual_clean,
          qual_clean AS content
   FROM `PROJECT_ID.abr_20_curated.v_verbatim`
   WHERE n_chars >= 25 AND NOT is_null_response),
  STRUCT(TRUE AS flatten_json_output, 'CLUSTERING' AS task_type)
);

CREATE OR REPLACE MODEL `PROJECT_ID.abr_40_semantic.verbatim_clusters`
OPTIONS (model_type = 'KMEANS', num_clusters = 12, standardize_features = TRUE) AS
SELECT embedding FROM `PROJECT_ID.abr_40_semantic.verbatim_embedding`;

CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.verbatim_cluster_member` AS
SELECT p.CENTROID_ID, p.doc_id, p.run_id, p.panel, p.meta, p.qual_clean,
       p.NEAREST_CENTROIDS_DISTANCE[OFFSET(0)].DISTANCE AS distance
FROM ML.PREDICT(MODEL `PROJECT_ID.abr_40_semantic.verbatim_clusters`,
                TABLE `PROJECT_ID.abr_40_semantic.verbatim_embedding`) p;

-- Coverage per cluster: what share of its members the codeframe already catches.
-- A cluster under ~60% is a gap worth reading.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_semantic.cluster_coverage` AS
WITH cov AS (
  SELECT m.CENTROID_ID, m.doc_id,
         EXISTS (SELECT 1 FROM `PROJECT_ID.abr_30_marts.verbatim_code` c
                 WHERE c.doc_id = m.doc_id) AS is_coded
  FROM `PROJECT_ID.abr_40_semantic.verbatim_cluster_member` m
)
SELECT
  c.CENTROID_ID,
  COUNT(*) AS size,
  ROUND(100.0 * COUNTIF(c.is_coded) / COUNT(*), 1) AS codeframe_coverage_pct,
  IF(100.0 * COUNTIF(c.is_coded) / COUNT(*) < 60, 'CODEFRAME GAP', '') AS flag,
  -- name the centroid from its own nearest members, not from a term list
  AI.GENERATE(
    CONCAT('These are the responses closest to one cluster centre in a film ',
           'trailer test. Name the single theme they share, in at most six words. ',
           'Responses:\n',
           (SELECT STRING_AGG(SUBSTR(m.qual_clean, 1, 300), '\n' ORDER BY m.distance)
            FROM (SELECT * FROM `PROJECT_ID.abr_40_semantic.verbatim_cluster_member` m2
                  WHERE m2.CENTROID_ID = c.CENTROID_ID
                  ORDER BY m2.distance LIMIT 15) m)),
    connection_id => 'us.vertex',
    endpoint => 'gemini-2.0-flash'
  ).result AS cluster_label
FROM cov c
GROUP BY c.CENTROID_ID;

-- Evidence quotes for a deck, without grepping:
-- SELECT base.qual_clean, distance
-- FROM VECTOR_SEARCH(
--   TABLE `PROJECT_ID.abr_40_semantic.verbatim_embedding`, 'embedding',
--   (SELECT ml_generate_embedding_result AS embedding
--    FROM ML.GENERATE_EMBEDDING(
--      MODEL `PROJECT_ID.abr_40_semantic.text_embedding`,
--      (SELECT 'the music and the yelling were too loud' AS content),
--      STRUCT(TRUE AS flatten_json_output, 'RETRIEVAL_QUERY' AS task_type))),
--   top_k => 10);
