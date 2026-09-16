/**
 * Single place for run-scoped study/format.
 * Set via workflow_settings.yaml vars or Dataform execution overrides
 * (Cloud Run will pass study_id + format_id per drop).
 */
const study_id = dataform.projectConfig.vars.study_id;
const format_id = dataform.projectConfig.vars.format_id;

if (!study_id || !format_id) {
  throw new Error(
    "Missing vars.study_id or vars.format_id. Set them in workflow_settings.yaml or the execution override."
  );
}

module.exports = { study_id, format_id };
