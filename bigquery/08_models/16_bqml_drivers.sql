-- ============================================================================
-- STAGE 7 — BQML: what actually drives intent
--
-- WHY bother at n=152: not for prediction — 152 rows will not produce a
-- deployable model. The value is ATTRIBUTION: which coded themes and which
-- closed-end reactions move intent, holding the others constant. That is a
-- question the crosstabs cannot answer, because the drivers are correlated
-- with each other.
--
-- BE HONEST ABOUT THE LIMIT: report AUC with the n beside it, and treat any
-- feature whose contribution is small as unresolved rather than unimportant.
--
-- Replace PROJECT_ID throughout.
-- ============================================================================

-- ---- 7.1  Feature table -----------------------------------------------------
-- One row per persona. Features are the coded qual themes (Stage 5c) plus the
-- equated latent scores on the reaction battery (Stage 5a). Label is high
-- intent on the equated axis, so it means the same thing in both cohorts.
CREATE OR REPLACE TABLE `PROJECT_ID.abr_40_marts.feat_intent` AS
WITH latent AS (
  SELECT f.archetype_id, f.question_key, m.latent_score
  FROM `PROJECT_ID.abr_20_curated.fct_response` f
  JOIN `PROJECT_ID.abr_30_semantic.option_scale_map` m
    ON f.instrument=m.instrument AND f.question_key=m.question_key
   AND f.selected_norm=m.option_norm
  WHERE f.question_type='single_select'
),
wide AS (
  SELECT archetype_id,
    MAX(IF(question_key IN ('Q9','Q10'),  latent_score, NULL)) AS intent_latent,
    MAX(IF(question_key IN ('Q11','Q12'), latent_score, NULL)) AS funny_latent,
    MAX(IF(question_key IN ('Q13','Q14'), latent_score, NULL)) AS exciting_latent,
    MAX(IF(question_key IN ('Q15','Q16'), latent_score, NULL)) AS rootfor_latent,
    MAX(IF(question_key IN ('Q19','Q20'), latent_score, NULL)) AS understand_latent,
    MAX(IF(question_key='Q23',            latent_score, NULL)) AS boring_latent,
    MAX(IF(question_key='Q25',            latent_score, NULL)) AS scary_latent,
    MAX(IF(question_key IN ('Q55','Q54'), latent_score, NULL)) AS bball_affinity_latent
  FROM latent GROUP BY archetype_id
),
themes AS (
  SELECT archetype_id,
    LOGICAL_OR(mentions_sensory_overload)                      AS said_too_loud,
    LOGICAL_OR(primary_theme='Boring or pacing')               AS said_boring,
    LOGICAL_OR(primary_theme='Comedy or humour')               AS said_funny,
    LOGICAL_OR(primary_theme='Dog or animal appeal')           AS said_dog,
    LOGICAL_OR(primary_theme='Sport or basketball')            AS said_sport,
    LOGICAL_OR(primary_theme='Friendship or teamwork')         AS said_friendship,
    COUNTIF(sentiment='Negative')                              AS n_negative_oes
  FROM `PROJECT_ID.abr_30_semantic.verbatim_coded`
  GROUP BY archetype_id
)
SELECT
  a.archetype_id, a.instrument, a.age, a.gender, a.ethnicity,
  a.behavioral_spark, a.adoption_category,
  w.* EXCEPT(archetype_id, intent_latent),
  t.* EXCEPT(archetype_id),
  -- Label: high intent on the equated axis. Threshold matches Stage 6's eq_t2b
  -- so the model and the mart mean the same thing by "positive intent".
  IF(w.intent_latent >= 60, 1, 0) AS high_intent
FROM `PROJECT_ID.abr_20_curated.dim_archetype` a
JOIN wide w USING (archetype_id)
LEFT JOIN themes t USING (archetype_id);

-- ---- 7.2  Logistic regression with explanations ----------------------------
-- L2 + auto class weights: n is small and the label is imbalanced (most
-- personas are positive), so without balancing the model just predicts "yes".
CREATE OR REPLACE MODEL `PROJECT_ID.abr_40_marts.model_intent_drivers`
OPTIONS (
  MODEL_TYPE = 'LOGISTIC_REG',
  INPUT_LABEL_COLS = ['high_intent'],
  L2_REG = 0.1,
  AUTO_CLASS_WEIGHTS = TRUE,
  ENABLE_GLOBAL_EXPLAIN = TRUE,
  DATA_SPLIT_METHOD = 'AUTO_SPLIT'
) AS
SELECT * EXCEPT(archetype_id) FROM `PROJECT_ID.abr_40_marts.feat_intent`;

-- Read AUC with n=152 beside it. Anything above ~0.75 here is encouraging;
-- do not quote it as a validated model.
SELECT * FROM ML.EVALUATE(MODEL `PROJECT_ID.abr_40_marts.model_intent_drivers`);

-- THE ANSWER QUERY: which features actually move intent.
SELECT * FROM ML.GLOBAL_EXPLAIN(MODEL `PROJECT_ID.abr_40_marts.model_intent_drivers`)
ORDER BY attribution DESC;

-- Watch specifically for said_too_loud. If the sensory complaint carries a
-- negative attribution on intent, the audio note stops being a qualitative
-- observation and becomes a quantified driver — which is a materially stronger
-- thing to put in front of a filmmaker.

-- ---- 7.3  Boosted trees — interaction diagnostic ---------------------------
-- Not a replacement model. If it materially beats the logistic AUC, there are
-- interaction effects (e.g. said_too_loud x age) the linear model is missing.
-- At n=152 expect small gains; a LARGE gain is more likely overfitting than
-- discovery, so check the eval split before believing it.
CREATE OR REPLACE MODEL `PROJECT_ID.abr_40_marts.model_intent_boosted`
OPTIONS (
  MODEL_TYPE = 'BOOSTED_TREE_CLASSIFIER',
  INPUT_LABEL_COLS = ['high_intent'],
  MAX_ITERATIONS = 30,
  LEARN_RATE = 0.1,
  SUBSAMPLE = 0.85,
  EARLY_STOP = TRUE
) AS
SELECT * EXCEPT(archetype_id) FROM `PROJECT_ID.abr_40_marts.feat_intent`;

SELECT * FROM ML.EVALUATE(MODEL `PROJECT_ID.abr_40_marts.model_intent_boosted`);
SELECT * FROM ML.FEATURE_IMPORTANCE(MODEL `PROJECT_ID.abr_40_marts.model_intent_boosted`)
ORDER BY importance_gain DESC;

-- ---- 7.4  Psychographic coherence ------------------------------------------
-- Do personas behave like their authored labels? Cross behavioral_spark against
-- intent. A near-diagonal pattern means the persona metadata is real. A
-- scrambled one means it is decoration — and THAT IS A FINDING WORTH
-- REPORTING, not a bug to bury.
SELECT
  behavioral_spark,
  COUNT(*)                                  AS personas,
  ROUND(AVG(high_intent)*100, 1)            AS pct_high_intent,
  CASE WHEN COUNT(*) < 30 THEN 'base too small to read' ELSE 'readable' END AS base_flag
FROM `PROJECT_ID.abr_40_marts.feat_intent`
GROUP BY behavioral_spark
ORDER BY pct_high_intent DESC;
