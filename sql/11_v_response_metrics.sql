-- The view every banner and model binds to.
--
-- Box metrics are NULL for multi-select questions. For those, primary_code is
-- just the lowest-numbered option someone happened to pick, so is_tb/is_bot
-- would be a confidently wrong number rather than an absent one.
--
-- is_bot / is_b2b additionally depend on scale_max, which is currently derived
-- from OBSERVED selections (see 09_dim_question.sql). Treat them as provisional
-- until the questionnaire supplies the designed option lists. is_tb / is_t2b
-- anchor on code 1 and are unaffected.
CREATE OR REPLACE VIEW `ff_20_curated.v_response_metrics` AS
SELECT *,
  IF(is_multi_select, NULL, primary_code = 1)                       AS is_tb,
  IF(is_multi_select, NULL, primary_code IN (1, 2))                 AS is_t2b,
  IF(is_multi_select, NULL, primary_code = scale_max)               AS is_bot,
  IF(is_multi_select, NULL, primary_code IN (scale_max - 1, scale_max)) AS is_b2b
FROM `ff_20_curated.fct_response`;
