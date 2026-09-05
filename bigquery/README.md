# ABR-TSR → BigQuery: analysis plan

**You run everything. I generate code only.** No step here has been executed, and nothing was
dry-run locally. Every file says what it does, why it exists, and what must be true before you
run the next one.

Run order is the directory order. Do not skip `03_checks` — it is the gate that stops bad
numbers reaching the marts.

---

## What the Vancouver file is, and what we take from it

`ABR_Frame1_Vancouver_Replica.xlsx` is from an **older study** and describes a run that was
never performed — its own README says *"No synthetic numbers exist yet."* It is a sample-frame
spec plus human benchmarks for a **full-film screening**, while T1/T23 are a **trailer** test on
a different instrument and a different population:

| | T1 + T23 (the new data) | Vancouver (the older study) |
|---|---|---|
| Stimulus | A **trailer** | The **full film** + key art + marketing |
| Instrument | Q1–Q55 trailer battery | Adult NRG v7 + Children's Form v7 (`CQ1…`) |
| Population | 152 kids, 4–12 | 84 adults + 81 kids |
| Gender | 50/50 | Kids **62% girl** |
| Ethnicity | 50% White, 8.6% Asian | **~52% Asian** |

So we do **not** join them, and we do not treat 78.4% as a target our trailer data must hit.

**What we take instead is its method.** The Vancouver file does something most synthetic-panel
work skips: it writes down the pass criteria *before* the run, and it gates on **structure**,
not only on levels —

> *"same character rank-order (Buddy #1) … pacing as softest element … the '~99%' quoted in the
> meeting was in-room enthusiasm, not the survey number."*

That is the transferable idea. Absolute levels need a human anchor. **Rank-order, replication
and known-answer accuracy do not.** Stage 9 rebuilds that discipline for the trailer study,
using the one thing this dataset has that Vancouver did not: **two independently generated
cohorts answering 24 identically-worded questions**, which is a natural replication test and
the closest thing to external validation available without fieldwork.

### Scope decision: kids only (confirmed)

Adults are out of scope — you have no adult synthetic panel, so there is nothing to analyse.
Note that Vancouver's *headline* gate was the adult one; its own rule reads *"FAIL on kids only
→ expected risk (kids are hardest to simulate)."* Worth carrying that humility into Stage 9:
kids are the hard case, and we are working only on the hard case.

**The plan therefore splits in two:**

- **Track A (Stages 1–8): the T1/T23 trailer study.** Fully valid on its own, and where the
  semantic top-box work pays off.
- **Track B (Stage 9): the validation architecture**, borrowed from Vancouver's mindset —
  pre-registered gates, cross-instrument replication, rank-order invariants, known-answer
  scoring, and generation-variance measurement. No human data required for any of it.

---

## The core idea: semantic scale equating

This is the part that answers *"get closer to real top-box, T2B and bottom-box."*

Your synthetic exports have **no numeric option codes** — `Q*_rating` and `Q*_rating_label`
are empty in all 6,103 cells. All quant is English label strings. On top of that, T1 uses a
2–3 point scale and T23 a 5-point scale **for the same construct**, and the human benchmark
uses a third scale again (NRG 5-point, 1 = best, adult Q1 mean 2.25).

Three scales, no codes. Ordinary top-box arithmetic cannot cross them — that is exactly how
the spurious "37–54 point appeal collapse" appeared in the earlier assessment.

**Stage 5 fixes this with AI, in four moves:**

1. **Rank the options.** `AI.GENERATE_TABLE` sees a question and *all of its sibling options at
   once*, and returns a rank plus a 0–100 latent favourability score for each. Ranking within
   the full option set is what makes this work — an option scored in isolation is meaningless.
2. **Validate the ranking** before using it (Stage 5b): strict monotonicity, rank count equals
   option count, and stability across two runs at `temperature = 0`. A ranking that fails is a
   bug, not a result.
3. **Equate.** Every option now sits on one 0–100 axis, so a 2-point and a 5-point scale become
   comparable. You get a scale-invariant **latent mean** alongside the raw boxes.
4. **Derive equated TB / T2B / BB at a common threshold** θ, rather than by counting boxes.
   θ is calibrated so that the human benchmark's own TB/T2B definition reproduces its published
   numbers — proper test equating, not a fudge factor.

You end up with, for every construct: raw TB/T2B/BB *per instrument* (correct but not
comparable), plus equated TB/T2B/BB and a latent mean (comparable across all three scales),
each with a Wilson confidence interval that tells the truth about n=43.

---

## Stages

| Stage | Directory | What it does | Gate before moving on |
|---|---|---|---|
| 1 | `01_setup/` | GCS bucket, 6 datasets, Vertex connection, remote models | Connection SA has `roles/aiplatform.user` |
| 2 | `02_load/` | Stage files to GCS, external tables, raw load (all STRING) | Row counts = 43 / 109 exactly |
| 3 | `03_checks/` | **Layer-input checks.** 14 assertions on the raw layer | All 14 `PASS` |
| 4 | `04_curated/` | `dim_archetype`, dynamic wide→long unpivot, `dim_question_option` | Fact rows reconcile to the counts in Stage 3 |
| 5 | `05_semantic/` | AI scale ranking + validation + verbatim coding + embeddings | Ranking monotonic and stable across 2 runs |
| 6 | `06_marts/` | Equated TB/T2B/BB, Wilson CIs, banner mart with base-size flags | No cell reported below n=30 without a flag |
| 7 | `08_models/` | BQML: intent drivers, theme clustering, feature importance | AUC reported honestly at n=152 |
| 8 | — | Push to GitHub | — |
| 9 | `07_calibration/` | Validation architecture: pre-registered gates, cross-instrument replication, rank invariants, stability | Gates declared **before** reading results |

---

## Which BigQuery data-science tools this uses, and what each is for

**Generative (needs the Vertex connection from Stage 1)**
- `AI.GENERATE_TABLE` — structured output against a fixed schema. Used twice: scale ranking
  (Stage 5a) and verbatim coding (Stage 5c). The workhorse of this pipeline.
- `AI.GENERATE` — free-text single values. Used to label cluster centroids in Stage 5e.
- `AI.GENERATE_BOOL` — cheap boolean flags where a full table is overkill.
- `ML.GENERATE_EMBEDDING` — vectors for clustering and search. **Pass
  `task_type = 'CLUSTERING'`**, not the default; it materially changes the space.

**Classical ML (no connection needed, runs in BigQuery)**
- `CREATE MODEL … MODEL_TYPE='KMEANS'` — emergent theme clusters over embeddings, as a check on
  whether your codeframe missed a theme.
- `CREATE MODEL … MODEL_TYPE='LOGISTIC_REG'` — what actually drives intent. `ENABLE_GLOBAL_EXPLAIN`
  gives you attribution.
- `CREATE MODEL … MODEL_TYPE='BOOSTED_TREE_CLASSIFIER'` — diagnostic only, to detect interaction
  effects the linear model misses. At n=152 expect marginal gains; that is the point of running it.
- `ML.EVALUATE`, `ML.PREDICT`, `ML.FEATURE_IMPORTANCE`, `ML.GLOBAL_EXPLAIN`, `ML.CENTROIDS`.

**Search and statistics**
- `VECTOR_SEARCH` — pull the nearest real verbatims to a probe sentence. This is how you source
  evidence quotes for a deck instead of grepping.
- `APPROX_QUANTILES`, `CORR`, `STDDEV` — distribution work in Stage 6.
- Hand-rolled **Wilson score intervals** — Stage 6. Normal-approximation CIs are wrong at n=43
  and near a 98% ceiling, and several of your headline numbers are exactly there.
- **Kish effective sample size** — Stage 9, to quantify what reweighting costs you.

**Console surfaces worth using**
- **BigQuery Studio → Data Canvas** for exploring the curated layer without writing SQL.
- **Saved queries + scheduled queries** to re-run Stage 3 checks on every reload.
- **BigQuery DataFrames (`bigframes`)** if you later want Python — it compiles to BigQuery SQL
  and does not pull data to your laptop. Not required for any stage here.

---

## Conventions

- **Everything raw loads as `STRING`.** Type casting happens in the curated layer, never at load.
  A silent load-time cast is unrecoverable.
- **`--allow_quoted_newlines` is mandatory.** Verbatims contain embedded newlines.
- **Region: one region for datasets, connection and models.** These files use `US`. A region
  mismatch is the single commonest reason `AI.*` fails with a confusing error.
- **`temperature = 0` on every AI call**, and the prompt text is versioned in git. A silent
  prompt edit re-codes the entire study and nothing in the output looks different.
- **Never overwrite a source column.** Derived values get new names (`*_norm`, `*_clean`).

## Cost

The data is tiny (1.7 MB). Storage and query cost is effectively zero. The only real spend is
AI calls: ~104 option labels for scale ranking (trivial), ~1,019 verbatims for coding, ~700 for
embeddings. Run Stage 5 on a `LIMIT 20` sample first and read the output before the full pass —
that is the one place where a wrong prompt costs real money and, worse, silently wrong codes.

## Verify before you build

I could not reach `docs.cloud.google.com` from this environment (egress blocked). The
generative function names and signatures below come from BigQuery knowledge, not from your
linked page. Before Stage 5, confirm in your console: `AI.GENERATE_TABLE`, `AI.GENERATE`,
`ML.GENERATE_EMBEDDING` argument shapes and the `output_schema` syntax. `AI.SEMANTIC_CLUSTER`
did not surface in search and I have deliberately **not** used it — Stage 5e uses embeddings +
`KMEANS`, which is the safe equivalent.
