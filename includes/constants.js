/**
 * Shared constants and SQL fragments. Nothing study-specific belongs here.
 */
const DB     = dataform.projectConfig.defaultDatabase;
const CONFIG = "`" + DB + "." + dataform.projectConfig.vars.config_dataset + "`";
const RAW    = "`" + DB + "." + dataform.projectConfig.vars.raw_dataset + "`";

/** Studies whose raw cells have landed and are ready to model. */
const BUILD_QUEUE = `
  SELECT study_id FROM ${CONFIG}.study_registry
  WHERE status IN ('ingested', 'configured', 'rebuild')
`;

/** Studies with a signed-off banner config, ready to render and export. */
const PUBLISH_QUEUE = `
  SELECT study_id FROM ${CONFIG}.study_registry
  WHERE status IN ('configured', 'rebuild')
`;

function inQueue(alias) {
  return `${alias}.study_id IN (${BUILD_QUEUE})`;
}

/**
 * Typed parse with an explicit failure channel.
 *
 * Never use a bare SAFE_CAST in this project. SAFE_CAST returns NULL on a
 * malformed value and the row vanishes with no counter and no assertion —
 * which is how a value like '9 years old' silently becomes a missing age.
 * Parse with these, then reconcile against stg_cast_reject.
 */
const PARSE_INT = (expr) =>
  `IF(REGEXP_CONTAINS(TRIM(${expr}), r'^-?[0-9]+$'), CAST(TRIM(${expr}) AS INT64), NULL)`;

/** First integer appearing anywhere in the string. Lossy by design — only
 *  for fields the format documents as free text, e.g. archetype_age_range. */
const LEAD_INT = (expr) =>
  `CAST(REGEXP_EXTRACT(TRIM(${expr}), r'([0-9]+)') AS INT64)`;

/**
 * Punch code from a selected cell. Handles both observed prefix shapes:
 *   '2. 2. Probably interested'  (doubled)
 *   '1. Action-packed'           (single)
 */
const PUNCH_CODE  = (e) => `CAST(REGEXP_EXTRACT(TRIM(${e}), r'^([0-9]+)\\s*\\.') AS INT64)`;
const PUNCH_LABEL = (e) =>
  `TRIM(REGEXP_REPLACE(TRIM(${e}), r'^([0-9]+\\s*\\.\\s*)+', ''))`;

module.exports = { DB, CONFIG, RAW, BUILD_QUEUE, PUBLISH_QUEUE, inQueue,
                   PARSE_INT, LEAD_INT, PUNCH_CODE, PUNCH_LABEL };
