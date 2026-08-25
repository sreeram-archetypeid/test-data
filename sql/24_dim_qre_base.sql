-- dim_qre_base: the questionnaire's conditional base rules, as data.
--
-- Source: ARENA_Fatal Fury Concept Test_Programming 061926.docx, the canonical
-- QRE. It gates 17 questions behind earlier answers. The synthetic panel did not
-- enforce any of them - every persona answered every question (F11) - so the
-- rules have to be reapplied downstream if banner bases are to mean anything.
--
-- This table exists so the routing logic is inspectable in the warehouse rather
-- than buried in a CASE expression. The CASE in 30_fct_response.sql implements
-- it; this records it, and Gate 6 checks the two agree.
--
-- expected_base_personas was measured from the source CSVs before any SQL was
-- written. expected_excluded_rows is at fct_response grain, which is NOT the
-- same as persona grain: PARENT2 sits in section 2.1, whose personas have two
-- replicate runs, so its 291 out-of-base personas become 435 rows. That grain
-- distinction is the same one that produced F2.
--
-- excluded_option_code carries the F10 rule: the theatre ACTIVITIES item screens
-- out "Never", so punch 6 leaves the base for that question only. It is a
-- different KIND of rule - dropping an answer rather than a respondent - but it
-- belongs here so every base rule lives in one place.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.dim_qre_base` AS
SELECT * FROM UNNEST([
  STRUCT(
    'PARENT2'   AS meta,
    'P1 "YES" @PARENT1'                            AS qre_rule,
    'parent1 = 1'                                  AS implemented_as,
    107                                            AS expected_base_personas,
    435                                            AS expected_excluded_rows,
    CAST(NULL AS INT64)                            AS excluded_option_code),
  STRUCT('POLORIENT', 'RESPONDENTS 18+',           'age_band_banner != "13-17"', 338,  60, NULL),
  STRUCT('LIKE',      'P1-P2 @ POSTINT1',          'postint IN (1,2)',           355,  43, NULL),
  STRUCT('DISLIKE',   'P2-P4 @ POSTINT1',          'postint IN (2,3,4)',         372,  26, NULL),
  STRUCT('URG2',      'P2-P4 AT URG1',             'urg1 IN (2,3,4)',            347,  51, NULL),
  STRUCT('ELEMENT2',  'P2-P4 AT URG1',             'urg1 IN (2,3,4)',            347,  51, NULL),
  STRUCT('PRELIKE1',  'P1 OR P5 AT RECONFIRM',     'reconfirm IN (1,5)',         393,   5, NULL),
  STRUCT('PRELIKE2',  'P1 OR P5 AT RECONFIRM',     'reconfirm IN (1,5)',         393,   5, NULL),
  STRUCT('RECONFIRM', 'P1-P3 DOWN @VGFRAN1',       'vgfran1_known',              398,   0, NULL)
]);
