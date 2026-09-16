-- ABR top / T2B / bottom — signed once for abr_persona_v1
-- Match is on cleaned option labels (after stripping "1. " / "1. 1. " prefixes).
-- Re-run anytime; safe REPLACE.

CREATE OR REPLACE TABLE `archetypeid-staging.svy_config.abr_box_defs` AS
SELECT * FROM UNNEST([
  -- ========== HTR: 5-pt "to what extent" (high = 5) ==========
  STRUCT('HTR' AS sample_arm, 'extent_5_high' AS scale_id, 'TOP BOX' AS box_kind,
         ['5 – To a very great extent'] AS option_labels),
  STRUCT('HTR', 'extent_5_high', 'T2B',
         ['5 – To a very great extent', '4 – To a great extent']),
  STRUCT('HTR', 'extent_5_high', 'BOTTOM BOX',
         ['1 – Not at all']),

  -- ========== HTR: 5-pt agree (high = 5) ==========
  STRUCT('HTR', 'agree_5_high', 'TOP BOX',
         ['5 – Strongly agree']),
  STRUCT('HTR', 'agree_5_high', 'T2B',
         ['5 – Strongly agree', '4 – Somewhat agree']),
  STRUCT('HTR', 'agree_5_high', 'BOTTOM BOX',
         ['1 – Strongly disagree']),

  -- ========== HTR: comfort ==========
  STRUCT('HTR', 'comfort_4_high', 'TOP BOX',
         ['Very comfortable']),
  STRUCT('HTR', 'comfort_4_high', 'T2B',
         ['Very comfortable', 'Somewhat comfortable']),
  STRUCT('HTR', 'comfort_4_high', 'BOTTOM BOX',
         ['Very uncomfortable']),

  -- ========== HTR: title like ==========
  STRUCT('HTR', 'title_like_5', 'TOP BOX',
         ['Like it a lot']),
  STRUCT('HTR', 'title_like_5', 'T2B',
         ['Like it a lot', 'Like it']),
  STRUCT('HTR', 'title_like_5', 'BOTTOM BOX',
         ['Do not like it at all']),

  -- ========== Kids K3: trailer like (3-pt) ==========
  STRUCT('K3', 'k3_like', 'TOP BOX',
         ['I liked it a lot']),
  STRUCT('K3', 'k3_like', 'T2B',
         ['I liked it a lot', 'It was okay']),
  STRUCT('K3', 'k3_like', 'BOTTOM BOX',
         ['I did not like it']),

  -- ========== Kids K9: trailer like (5-pt) ==========
  STRUCT('K9', 'k9_like', 'TOP BOX',
         ['I liked it a lot!']),
  STRUCT('K9', 'k9_like', 'T2B',
         ['I liked it a lot!', 'I liked it!']),
  STRUCT('K9', 'k9_like', 'BOTTOM BOX',
         ['I did not like it.']),

  -- ========== Kids K3: funny ==========
  STRUCT('K3', 'k3_funny', 'TOP BOX',
         ['Very funny']),
  STRUCT('K3', 'k3_funny', 'T2B',
         ['Very funny', 'A little funny']),
  STRUCT('K3', 'k3_funny', 'BOTTOM BOX',
         ['Not funny']),

  -- ========== Kids K9: funny ==========
  STRUCT('K9', 'k9_funny', 'TOP BOX',
         ['Super funny']),
  STRUCT('K9', 'k9_funny', 'T2B',
         ['Super funny', 'Very funny']),
  STRUCT('K9', 'k9_funny', 'BOTTOM BOX',
         ['Not funny at all']),

  -- ========== Kids K3: want to see (yes/maybe/no) ==========
  STRUCT('K3', 'k3_want', 'TOP BOX',
         ['Yes!']),
  STRUCT('K3', 'k3_want', 'T2B',
         ['Yes!', 'Maybe']),
  STRUCT('K3', 'k3_want', 'BOTTOM BOX',
         ['No']),

  -- ========== Kids K9: want to see ==========
  STRUCT('K9', 'k9_want', 'TOP BOX',
         ['I really want to see it']),
  STRUCT('K9', 'k9_want', 'T2B',
         ['I really want to see it', 'I want to see it']),
  STRUCT('K9', 'k9_want', 'BOTTOM BOX',
         ['I really do not want to see it'])
]);

-- Map question text → scale_id (arm-specific where instruments differ)
CREATE OR REPLACE TABLE `archetypeid-staging.svy_config.abr_question_boxes` AS
SELECT * FROM UNNEST([
  -- HTR extent family (Q16–Q25 style wording)
  STRUCT(CAST(NULL AS STRING) AS sample_arm, 'extent_5_high' AS scale_id,
         r'(?i)to what extent did the movie look' AS question_regex),
  STRUCT(NULL, 'agree_5_high',
         r'(?i)how much do you agree or disagree with the statement'),
  STRUCT(NULL, 'comfort_4_high',
         r'(?i)how comfortable would you be allowing'),
  STRUCT(NULL, 'title_like_5',
         r'(?i)how much do you like this title'),

  -- Kids — arm-specific because labels differ
  STRUCT('K3', 'k3_like', r'(?i)how much did you like the trailer'),
  STRUCT('K9', 'k9_like', r'(?i)how much did you like the trailer'),
  STRUCT('K3', 'k3_funny', r'(?i)how funny did the movie look'),
  STRUCT('K9', 'k9_funny', r'(?i)how funny did the movie look'),
  STRUCT('K3', 'k3_want', r'(?i)do you want to see this movie|how much do you want to see this movie'),
  STRUCT('K9', 'k9_want', r'(?i)how much do you want to see this movie')
]);
