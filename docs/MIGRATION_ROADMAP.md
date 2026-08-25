# BigQuery migration — status and roadmap

Supersedes the execution checklist in `BIGQUERY_MIGRATION_PLAN.md` §14. That
document is still the analytical brief; this one is the live status board.

Section references like *§6* point back into `BIGQUERY_MIGRATION_PLAN.md`.

---

## Where we are

**Phase 1 (Land & Shape) is complete and green.** The READ modality is fully
modelled in BigQuery, from raw CSV through to banner-ready tables, with every
number asserted against the source files.

| | Assertions | Status |
|---|---:|---|
| Gate 1 — raw landed | 3 | ✅ 596 / 398 / 398 = 1,392 rows |
| Staging — unpivot + parse | 11 | ✅ 40,178 rows |
| Gates 2 / 2b / 3 — dimensions | 49 | ✅ 398 / 12 / 91 / 334 |
| Gate 5 — metric model | 26 | ✅ 54/15/9/2/1/10 classified |
| Gates 4 + 6 — fact + QRE base | 30 | ✅ 40,178 rows, 39,502 in base |
| Marts — banner tables | 22 | ✅ both bases, 81 questions |
| DQ suite (re-runnable) | 44 | ✅ 44/44 |
| | **185** | |

Fourteen defects were found and fixed along the way, each with a permanent
regression guard — see `docs/PHASE1_RUNBOOK.md` (F1–F8, F13) and
`docs/QUESTIONNAIRE_FINDINGS.md` (F9–F12, F14).

### What exists in BigQuery now

```
ff_00_raw        raw_read_s21/s22/s23                   1,392 rows, all STRING
ff_10_staging    stg_response_s21/s22/s23, stg_response 40,178 rows, parsed
ff_20_curated    dim_archetype           398   personas
                 dim_run                  12   source files
                 dim_question             91   questions
                 dim_question_option     334   (question, option) pairs
                 dim_qre_base              9   routing rules
                 fct_response         40,178   persona × run × question
                 fct_response_option  39,490   one row per selected option
                 v_response_metrics   (view)   box metrics, gated by type
ff_30_marts      dim_archetype_cuts      398   behavioural cut flags
                 mart_banner_read     (long)   banner cells, both bases
                 dq_results         (append)   every DQ run, timestamped
```

Full explanation of each layer and table: `docs/PHASE1_EXPLAINED.md`.

### Deferred from Phase 1, by decision

- **QA notebook** — designed in `docs/PHASE1_QA_CHARTS.md`, not built. The gates
  already cover correctness; this was visual confirmation.
- **`tools/validate_local.py`** — an independent Python recomputation of every
  gate from the CSVs. Worth building the next time a number is disputed.

---

## Phase 2 — Banner validation against the delivered deck

**Next, and it should be next.** Cheapest step with the highest confidence
payoff: before anything is modelled on these numbers, confirm they reproduce
figures a human already published.

`Support Files/FATAL_FURY_CHART_REPORT_July_20_2026.pptx` and the four
`FF_*_BannerPlan_*.xlsx` files contain delivered percentages. Our
`mart_banner_read` should reproduce the READ ones.

1. Extract the reported figures for READ from the PPTX / banner plans into a
   small reference table (a CSV in the repo, so it is reviewable).
2. Join it to `mart_banner_read` on `(meta, cut_name, cut_value, metric_name)`.
3. Report every cell where we differ by more than rounding, with both numbers.
4. Investigate each difference: our bug, their different base, or a genuine
   discrepancy worth raising.

**Why first:** a mismatch here invalidates everything downstream, and a match is
the strongest possible evidence the model is right. It also settles several open
research-lead questions by observation instead of by asking.

**Deliverables:** `sql/50_mart_validation.sql`, `tools/validate_banners.sh`,
`docs/BANNER_VALIDATION.md`.

---

## Phase 3 — Analysis and models (§10)

Only after Phase 2. Three pieces from §10.2, in order of value:

1. **Headline read** — `POSTINT` top-box and top-2-box by creative, with all
   nine banner cuts. This is the commercial answer: does Goyer or Sheridan test
   better, and with whom. *(Includes the top-box work parked at the start of
   Phase 1 — the mechanics are built and verified; this is reading the numbers.)*
2. **Driver analysis** — what moves `POSTINT` top-box. Outcome: TB. Features:
   demographics, genre fandom, franchise familiarity, element ratings. Report
   effect sizes with confidence intervals, not just a ranking.
3. **Answer-stability analysis** (§10.3) — already half done. The replicate
   agreement measurement in `docs/PHASE1_QA_CHARTS.md` (86.7% overall; 100% on
   facts, ~80% on 6-point scales) is the input. Formalise it as a reliability
   statistic per question, and use it to put error bars on every other finding.

**Note on scope:** `ELEMENT2` figures must always be reported with both
creatives' bases stated, never pooled — its routing gate excludes 29 Goyer
personas but only 22 Sheridan (F14).

---

## Phase 4 — Open-end / verbatim coding

10 of the 91 questions are open-ended and are excluded from `mart_banner_read` by
design. They carry **17,301 verbatims** — the richest unexploited asset in the
warehouse, and where most of the QRE routing work pays off.

Seven of the nine QRE-routed questions are open-ends (`PARENT2`, `LIKE`,
`DISLIKE`, `URG2`, `PRELIKE1`, `PRELIKE2`), so `is_in_qre_base` on
`fct_response` matters far more here than it does in the banner mart. `PARENT2`
alone has 291 personas who should never have been asked.

1. Code the verbatims into themes (LLM-assisted, human-reviewed sample).
2. Land the codes as `fct_response_theme` at `(persona, run, question, theme)`
   grain — same pattern as `fct_response_option`.
3. Extend `mart_banner_read` to emit theme incidence, honouring `is_in_qre_base`.

---

## Phase 5 — Human-panel calibration (§12)

The question the whole synthetic-panel exercise exists to answer: **does the
panel track real people?**

`Final W Tabs (1)/` holds the human study (N=800) as four CSVs — Banner 1 and 2,
frequencies and percentages. Comparing our figures to those is the validation
that matters.

1. Build a W-Tabs-row → `question_key` mapping. This is the real work; the
   tabs are formatted for print, not for joining.
2. Compare on the QRE base (the only base comparable to a fielded survey — this
   is why `is_in_qre_base` exists).
3. Report agreement per question and per cut. Where the panel diverges, say by
   how much and in which direction.

**Prerequisite:** the 998 → 398 split must be documented first. We cannot claim
the 398 personas are representative of anything until we know how they were
selected from the 998.

---

## Phase 6 — Onboarding AUDIO and VIDEO (§11)

READ is one of three modalities; 398 of 998 personas. The pipeline was built to
extend, not to be rewritten:

- `modality` already exists as a column on `dim_archetype` and `fct_response`,
  currently constant `'READ'`.
- The generators (`tools/gen_raw_schema.py`, `gen_unpivot.py`) read real CSV
  headers, so new files with different question counts need a config entry, not
  new code.
- Every gate expectation is a measured constant, so each new modality needs its
  own measured numbers — that is the work, and it is deliberate.

Banner plans for both already exist in `Support Files/`.

---

## Open items blocking nothing, affecting interpretation

Carried forward from `docs/RESEARCH_LEAD_QUESTIONS.md`. None stops the build;
all affect how numbers are read.

| Item | Impact if wrong |
|---|---|
| **998 → 398 split** undocumented | blocks Phase 5 representativeness claims |
| **EXPOSURE ORDER** — 8 of 9 banner cuts built | one banner column missing; nothing in the CSVs encodes it |
| **G / S = Goyer / Sheridan** — inferred | creative labels wrong everywhere if not |
| **`17-24` age band** imputed for 22 personas | 22 personas move between age cuts |
| **`Wanoo-Bagoo [FOIL]`** handling | a foil concept may be counted as real |
| **Income banding** on midpoint vs low | 13 personas move between income cuts |
| **Replicate direction** — standalone vs `2.1X` primary | ~~open~~ **largely answered**: 86.7% agreement, facts stable, so both runs are genuine (F15). Confirm the preference order with the research lead. |

---

## Operating the pipeline

Full rebuild from scratch, in order. Each script refuses to run if a placeholder
is unsubstituted, and exits non-zero if any assertion fails.

```bash
source config.env
./tools/slugify_upload.sh        # 12 CSVs -> GCS with safe names
./tools/land_raw.sh              # Gate 1
./tools/shape_staging.sh         # unpivot + parse, 11 assertions
./tools/build_curated_dims.sh    # Gates 2 / 2b / 3, 49 assertions
./tools/build_metric_model.sh    # Gate 5, 26 assertions
./tools/build_fct.sh             # Gates 4 + 6, 30 assertions
./tools/build_marts.sh           # 22 structural checks
./tools/run_dq.sh                # DQ suite, 44 assertions
```

Every step is `CREATE OR REPLACE` and safe to re-run. `./tools/run_dq.sh
--history` shows pass counts across past rebuilds. Any script accepts
`--dry-run` to print the resolved SQL, including its assertion block, without
touching BigQuery.
