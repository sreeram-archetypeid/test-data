-- ============================================================================
-- STAGE 5d/5e — EMBEDDINGS, CLUSTERING, VECTOR SEARCH
--
-- WHY, given Stage 5c already coded the verbatims: 5c imposes YOUR codeframe.
-- This stage lets themes emerge on their own, as a check that the codeframe did
-- not miss something. A cluster that predicts intent but has no closed-end
-- equivalent is the sensory finding repeating itself — that is the pattern to
-- hunt for, and it is how the sensory gap would have been found automatically.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

-- ---- 5d.1  Embed --------------------------------------------------------
-- task_type = 'CLUSTERING' is not cosmetic: it changes the geometry of the
-- space. The default (or SEMANTIC_SIMILARITY) optimises for pairwise likeness,
-- which produces worse-separated clusters.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.verbatim_embeddings` AS
SELECT *
FROM ML.GENERATE_EMBEDDING(
  MODEL `PROJECT_ID.abr_30_semantic.text_embedding`,
  (SELECT archetype_id, instrument, question_key, age, age_band, gender,
          qual_clean AS content
   FROM `PROJECT_ID.abr_20_curated.v_verbatim_corpus`
   WHERE question_key IN ('Q4','Q5','Q6','Q30','Q31','Q32')),
  STRUCT('CLUSTERING' AS task_type)
);

-- ---- 5e.1  Cluster ------------------------------------------------------
-- k=7 for ~700 documents is a starting point, not a finding. Run k = 5..9 and
-- compare Davies-Bouldin from ML.EVALUATE; take the elbow, and sanity-read the
-- members. COSINE because embedding magnitude carries no meaning here.
CREATE OR REPLACE MODEL `PROJECT_ID.abr_30_semantic.theme_clusters`
OPTIONS (
  MODEL_TYPE = 'KMEANS',
  NUM_CLUSTERS = 7,
  DISTANCE_TYPE = 'COSINE',
  STANDARDIZE_FEATURES = FALSE   -- embeddings are already on a common scale
) AS
SELECT ml_generate_embedding_result
FROM `PROJECT_ID.abr_30_semantic.verbatim_embeddings`;

-- Cluster quality. Lower Davies-Bouldin is better. Compare across k.
SELECT * FROM ML.EVALUATE(MODEL `PROJECT_ID.abr_30_semantic.theme_clusters`);

-- ---- 5e.2  Assign, then let the model name each cluster ------------------
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.verbatim_clustered` AS
SELECT e.archetype_id, e.instrument, e.question_key, e.age_band, e.gender,
       e.content, p.CENTROID_ID AS cluster_id
FROM ML.PREDICT(MODEL `PROJECT_ID.abr_30_semantic.theme_clusters`,
     TABLE `PROJECT_ID.abr_30_semantic.verbatim_embeddings`) p
JOIN `PROJECT_ID.abr_30_semantic.verbatim_embeddings` e
  USING (archetype_id, question_key);

-- Name the clusters from their actual members, rather than guessing from
-- centroid coordinates (which are uninterpretable for text embeddings).
CREATE OR REPLACE TABLE `PROJECT_ID.abr_30_semantic.cluster_labels` AS
SELECT cluster_id, n_members, cluster_label, distinguishing_feature
FROM AI.GENERATE_TABLE(
  MODEL `PROJECT_ID.abr_30_semantic.gemini_text`,
  (SELECT cluster_id, COUNT(*) AS n_members,
          CONCAT('These are open-end responses from children about a movie trailer, ',
                 'grouped by an unsupervised clustering. Read them and name the theme ',
                 'they share.\n\nRESPONSES:\n',
                 STRING_AGG(CONCAT('- ', content), '\n' LIMIT 40),
                 '\n\nReturn a 2-5 word cluster_label naming the shared theme, and a ',
                 'one-sentence distinguishing_feature saying what separates this group ',
                 'from other responses about the same trailer.') AS prompt
   FROM `PROJECT_ID.abr_30_semantic.verbatim_clustered`
   GROUP BY cluster_id),
  STRUCT('cluster_label STRING, distinguishing_feature STRING' AS output_schema,
         0.0 AS temperature)
);

-- ---- 5e.3  THE PAYOFF QUERY ---------------------------------------------
-- Cross emergent clusters against the closed-end intent measure. A cluster
-- that skews hard on intent but corresponds to no closed-end option is a blind
-- spot in the questionnaire — exactly what the sensory finding was.
CREATE OR REPLACE VIEW `PROJECT_ID.abr_40_marts.v_cluster_vs_intent` AS
SELECT
  c.cluster_id,
  l.cluster_label,
  COUNT(DISTINCT c.archetype_id)                       AS personas,
  ROUND(AVG(m.latent_score), 1)                        AS mean_intent_latent,
  ROUND(AVG(m.latent_score)
        - (SELECT AVG(m2.latent_score)
           FROM `PROJECT_ID.abr_20_curated.fct_response` f2
           JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m2
             ON f2.instrument=m2.instrument AND f2.question_key=m2.question_key
            AND f2.selected_norm=m2.option_norm
           WHERE f2.question_key IN ('Q9','Q10')), 1)  AS lift_vs_total
FROM `PROJECT_ID.abr_30_semantic.verbatim_clustered` c
JOIN `PROJECT_ID.abr_30_semantic.cluster_labels` l USING (cluster_id)
JOIN `PROJECT_ID.abr_20_curated.fct_response` f
  ON f.archetype_id = c.archetype_id AND f.question_key IN ('Q9','Q10')
JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
  ON f.instrument = m.instrument AND f.question_key = m.question_key
 AND f.selected_norm = m.option_norm
GROUP BY 1,2
ORDER BY mean_intent_latent DESC;

-- ---- 5e.4  Evidence retrieval for the deck ------------------------------
-- Give it a probe sentence, get the nearest real verbatims back, ranked.
-- Better than grepping, and it finds paraphrases your regex would miss.
--
-- (Optional, for speed at larger corpora — unnecessary at ~700 docs:
--  CREATE VECTOR INDEX idx ON abr_30_semantic.verbatim_embeddings(
--    ml_generate_embedding_result) OPTIONS(index_type='IVF',
--    distance_type='COSINE');)
SELECT base.content, base.age_band, base.question_key, distance
FROM VECTOR_SEARCH(
  TABLE `PROJECT_ID.abr_30_semantic.verbatim_embeddings`,
  'ml_generate_embedding_result',
  (SELECT ml_generate_embedding_result AS qv
   FROM ML.GENERATE_EMBEDDING(
     MODEL `PROJECT_ID.abr_30_semantic.text_embedding`,
     (SELECT 'the music was too loud and it hurt my ears' AS content),
     STRUCT('CLUSTERING' AS task_type))),
  'qv',
  top_k => 20,
  distance_type => 'COSINE')
ORDER BY distance;
