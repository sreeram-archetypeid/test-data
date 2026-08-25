-- fct_response: the analysis contract. One row per (persona, run, question).
-- Expected 40,178 rows.
--
-- This is the table analysts and models bind to. Everything upstream of it is
-- implementation detail; everything downstream reads only from here and the
-- dimensions.
--
-- The replicate resolution
-- -----------------------
-- Section 2.1 was run twice for cohorts G.2 and S.1 -- same personas, same 20
-- questions, different answers. Nothing is deduplicated, so the grain includes
-- run_id and 3,960 (persona, question) keys carry two rows each.
--
-- is_primary_run picks one row per (persona, question) deterministically: the
-- standalone file beats the combined 2.1X file. For the 32,258 single-run keys
-- it is a no-op. Any query crossing sections MUST filter on it, or it
-- double-counts 198 personas.
--
--   ORDER BY ENDS_WITH(run_id, 'x')  ->  FALSE (0) sorts first  ->  standalone wins
--
-- Note this is the one modelling choice still awaiting research-lead
-- confirmation (Appendix A item 5): if the standalone 2.1 files turn out to be
-- discarded pilots rather than valid replicates, the ORDER BY flips. Everything
-- else is unaffected, which is why the rule lives in exactly one place.
--
-- primary_code
-- ------------
-- The lowest non-sentinel option code on the row. Sentinels (>= 90, i.e.
-- '99. None of the above') are excluded per D9 -- which only works because
-- option_code is read from the code prefix rather than the position prefix
-- (F5).
--
-- It is NULL on 5,587 rows: the 4,574 open-ends and 596 numeric ratings have no
-- selections at all, plus 417 rows where the respondent's only selection WAS a
-- sentinel. That last group is a real answer ("none of these"), not missing
-- data -- treat it as such downstream.
--
-- is_in_qre_base
-- --------------
-- The QRE routes 17 questions; the panel answered all of them for everyone.
-- This flag reapplies the routing so banner bases match how the human study
-- (N=800, fielded through a real survey engine) would have run. 676 rows are
-- excluded -- note that is ROW grain: PARENT2 is in section 2.1, whose personas
-- carry two replicate runs, so its 291 out-of-base personas become 435 rows.
--
-- Nothing is deleted. Banners choose their base explicitly and declare it.
--
-- Physical layout
-- ---------------
-- Clustered, never date-partitioned. 40,178 rows is four orders of magnitude
-- below where partitioning earns anything; partitions of a few hundred rows
-- would scan and cost more. Cluster order matches real query shape: modality
-- and creative filter first, then question, then cut.

CREATE OR REPLACE TABLE `${PROJECT_ID}.${DS_CUR}.fct_response`
CLUSTER BY modality, creative, meta, cohort_code AS
WITH
-- F11: the QRE gates 17 questions behind earlier answers; the synthetic panel
-- enforced none of them. These are the gating answers per persona, taken from
-- stg_response rather than from fct_response because primary_code is derived in
-- this same query -- reading it back would be circular.
persona_gates AS (
  SELECT
    s.archetype_id,
    MIN(IF(s.meta = 'POSTINT',   s.pc, NULL)) AS postint,
    MIN(IF(s.meta = 'URG1',      s.pc, NULL)) AS urg1,
    MIN(IF(s.meta = 'PARENT1',   s.pc, NULL)) AS parent1,
    MIN(IF(s.meta = 'RECONFIRM', s.pc, NULL)) AS reconfirm,
    LOGICAL_OR(s.meta = 'VGFRAN1' AND s.pc IN (1, 2, 3)) AS vgfran1_known
  FROM (
    SELECT
      archetype_id, meta,
      (SELECT MIN(o.option_code) FROM UNNEST(selected_options) AS o
       WHERE o.option_code < 90) AS pc
    FROM `${PROJECT_ID}.${DS_STG}.stg_response`
  ) AS s
  GROUP BY s.archetype_id
),
scale AS (
  SELECT DISTINCT question_key, scale_max
  FROM `${PROJECT_ID}.${DS_CUR}.dim_question_option`
),
joined AS (
  SELECT
    s.*,
    a.modality,
    a.creative,
    a.cohort_code,
    a.age_band_banner AS _age_band,   -- helper for the QRE 18+ gate; dropped below
    ROW_NUMBER() OVER (
      PARTITION BY s.archetype_id, s.question_key
      ORDER BY ENDS_WITH(s.run_id, 'x') ASC, s.run_id ASC
    ) AS run_rank,
    COUNT(*) OVER (
      PARTITION BY s.archetype_id, s.question_key
    ) AS run_count
  FROM `${PROJECT_ID}.${DS_STG}.stg_response` AS s
  JOIN `${PROJECT_ID}.${DS_CUR}.dim_archetype` AS a
    USING (archetype_id)
)
SELECT
  j.* EXCEPT (run_rank, run_count, _age_band),
  (j.run_rank = 1) AS is_primary_run,
  j.run_count      AS n_runs_for_question,
  (
    SELECT MIN(o.option_code)
    FROM UNNEST(j.selected_options) AS o
    WHERE o.option_code < 90
  ) AS primary_code,
  sc.scale_max,

  -- F11: TRUE for every ungated question, so `WHERE is_in_qre_base` is safe to
  -- apply universally and only bites on the nine the QRE actually routes.
  -- Rules mirrored in dim_qre_base; Gate 6 checks the two agree.
  CASE j.meta
    WHEN 'PARENT2'   THEN g.parent1 = 1
    WHEN 'POLORIENT' THEN j._age_band != '13-17'
    WHEN 'LIKE'      THEN g.postint IN (1, 2)
    WHEN 'DISLIKE'   THEN g.postint IN (2, 3, 4)
    WHEN 'URG2'      THEN g.urg1 IN (2, 3, 4)
    WHEN 'ELEMENT2'  THEN g.urg1 IN (2, 3, 4)
    WHEN 'PRELIKE1'  THEN g.reconfirm IN (1, 5)
    WHEN 'PRELIKE2'  THEN g.reconfirm IN (1, 5)
    WHEN 'RECONFIRM' THEN g.vgfran1_known
    ELSE TRUE
  END AS is_in_qre_base

FROM joined AS j
LEFT JOIN scale AS sc
  ON sc.question_key = j.question_key
JOIN persona_gates AS g
  ON g.archetype_id = j.archetype_id;
