# Phase 3 — driver model, AI-coded verbatims, and self-validation

## Context

Phase 1 built the warehouse. Phase 2 proved the pipeline correct and found the
panel wanting, by comparing 10,090 cells against a human N=800 study.

Phase 3 has to work **without that human study**. There will not be a W-Tabs
file for the next concept test, and if the answer to "can we trust this?" is
"compare it to human data", the product does not exist. So the central question
of this phase is not the driver model or the verbatims. It is:

> **What can we establish about a synthetic panel using only the panel itself?**

The honest answer has a hard boundary, and stating it plainly is the first
deliverable:

- **External validity cannot be established from internal evidence.** Whether
  44% of real people would say "definitely interested" is a fact about the
  world. No amount of internal consistency will recover it. Any claim otherwise
  is false and will eventually be caught.
- **Almost everything else can be.** Pipeline correctness, reliability,
  response-bias, degeneracy, run-to-run stability, and agreement with free
  public benchmarks are all measurable with no client study at all — and every
  one of them was a real defect risk on this project.

The practical consequence: we stop trying to certify *accuracy* and start
certifying *fitness for use*, per question, with a published reason.

## What is already established, and what it cost

Phase 2 ended with two independent implementations of the same comparison —
Python from the raw CSVs, SQL in BigQuery — sharing no code. Gate 6 of
`tools/validate_banners.sh` compares them cell by cell.

That redundancy is not ceremony. It caught a real defect: the two disagreed on
196 cells because the local build was applying **none** of the questionnaire's
base rules, so POLORIENT was divided by 398 instead of 338 and the theatre item
by 398 instead of 396. Their numbers had matched all along; only ours were
wrong. They now agree on all 10,090 cells to six decimal places.

**This is the model for Phase 3.** Every number that matters gets computed twice
by different means, and the two are gated against each other. It is the only
check that survives having no benchmark.

---

## Part A — Self-validation without human data

Six families of check, ordered by how much they tell you per unit of effort.
Three are already measured; the numbers below are real, not targets.

### A1 — Test–retest reliability *(measured, no benchmark needed)*

Section 2.1 was asked twice of the same personas: 3,960 (persona, question)
pairs. That is a free reliability study, and it bounds how much of any finding
is noise.

| Question | Agreement |
|---|---:|
| Screener 2 (country) | 198/198 — **100%** |
| Screener 1 | 56/56 — **100%** |
| PARENT1 | 196/198 — **99.0%** |
| GFAN1 (genre fandom, 4-point) | 1306/1584 — **82.4%** |
| ACTIVITIES (frequency, 6-point) | 753/990 — **76.1%** |
| **Overall** | **2,509/3,026 — 82.9%** |

Read this correctly: **factual questions are perfectly reliable and opinion
scales are not.** A 6-point frequency question disagrees with itself a quarter
of the time. That alone caps how finely any opinion measure can be cut — a 5pp
difference on ACTIVITIES is inside the panel's own test–retest noise, so it is
not a finding, whatever the banner says.

**Action:** make this a standing gate. Every future delivery repeats one section,
and the per-question retest rate becomes a published reliability coefficient
that sits next to every number derived from it.

### A2 — Degeneracy screen *(measured, no benchmark needed)*

The Phase 2 headline — one-dimensional personas — is detectable **without any
human data**. Concentration of answers is visible on its face:

| Top option's share | Questions |
|---|---:|
| ≥90% (no usable variance) | **11** |
| 75–90% | 17 |
| 50–75% | 34 |
| <50% (well spread) | 18 |

`GFAN1 / Martial Arts` sits at 92.5% in one option out of three. A banner column
cut on that question cannot discriminate anything, and you can see that from our
data alone — the human study only confirmed it.

**Caveat, and the work:** this screen is currently too blunt to be a gate. It
does not yet distinguish `multi_select` batteries, where a high top-share can be
legitimate, from single-punch questions where it is fatal. It must be split by
`metric_kind` before it becomes an assertion. Treat the 11 as flagged for
review, not condemned.

**Action:** implement per-`metric_kind`, publish an *effective sample size* per
question, and refuse to emit a banner column whose cut question is degenerate,
rather than emitting one that reads 7/8/8/7.

### A3 — Negative controls *(new, and the cheapest strong test)*

Nothing here yet, and it is the highest-value addition in this plan. Insert into
the questionnaire:

- **A franchise that does not exist.** If personas report familiarity with an
  invented title, that quantifies acquiescence bias directly. There is no
  ambiguity in the result and no benchmark required.
- **A reversed-polarity duplicate** of a real question. A persona agreeing with
  both a statement and its negation is measurable response-set bias.
- **Rotated option order** across personas. If the distribution moves with the
  order, that is primacy bias, and it is a number.

These cost a handful of questions and yield hard bias coefficients. Everything
else in this section measures *consistency*; this measures *whether the
instrument is being answered at all*.

### A4 — Run-to-run variance *(new)*

An LLM panel has no sampling error in the classical sense, but it does have
generation variance, and right now every figure is reported as though it were
exact. Regenerate the full panel under a different seed and the between-run
spread per cell becomes the honest error bar.

**Action:** two or three full regenerations, then publish a confidence interval
per banner cell. A gap smaller than the between-run spread is not a finding.
This replaces significance testing, which does not apply here — and it is worth
saying that plainly, because a naive z-test on n=398 will produce
confident-looking nonsense.

### A5 — Free external benchmarks *(new, and it changes the framing)*

"No human data" is not the same as "no benchmark". Age, gender, income,
education and region all have authoritative public distributions — Census ACS,
GSS, Nielsen — and they are free, permanent, and available before any study is
commissioned.

The Phase 2 income finding needed no client tabs. Our panel's minimum income is
**$35,000** and not one of 398 personas falls below it, where the human sample
put 27% under $40,000. **ACS would have caught that on day one.**

**Action:** a standing quota-audit against public data for every attribute that
has one. This is the single largest reduction in dependence on client tabs.

### A6 — Criterion validity *(new, the hardest and most valuable)*

The question a client actually cares about is whether the panel *ranks* concepts
correctly. That can be tested against outcomes already known:

Score a set of already-released titles with the same instrument and check
whether the panel's intent measure ranks their actual box office. It does not
need this study's humans — it needs history.

If the panel cannot rank known outcomes, no amount of internal consistency makes
it fit for a go/no-go decision. If it can, that is the strongest claim available
without a fresh human sample, and it is a claim about *decisions* rather than
percentages.

---

## Part B — Verbatims, AI-coded

10 open-end questions, **4,571 verbatims**. The first check is already done and
it is good news:

| meta | n | unique | median words | most-repeated 5-gram |
|---|---:|---:|---:|---:|
| Screener 2 | 596 | 596 (100%) | 34 | 0.15% |
| LIKE | 398 | 398 (100%) | 40 | 0.11% |
| DISLIKE | 398 | 398 (100%) | 39 | 0.10% |
| URG2 | 397 | 397 (100%) | 28 | 0.05% |
| *(all 10 questions)* | 4,571 | **100% unique** | 28–42 | ≤0.24% |

**No template collapse at the surface.** Every verbatim is distinct and phrase
reuse is negligible. This is a sharp contrast with the closed questions, where 11
have almost no variance — and it is a finding in itself: the generator produces
varied prose while producing near-identical scale answers.

That contrast is a warning, not a reassurance. Distinct wording around a
uniform opinion is exactly what fluent generation looks like, so **lexical
diversity must not be reported as evidence of attitudinal diversity.** The next
checks have to go past the surface:

1. **Semantic** diversity, not lexical — embed and measure spread. 100% unique
   strings can still be 100% the same opinion.
2. **Code the verbatims with an LLM** against a codeframe, then measure
   agreement with human coding on a sample. Without that, AI coding is an
   unvalidated instrument reporting on an unvalidated panel.
3. **Stability**: code the same verbatim twice and measure agreement, exactly as
   A1 does for closed questions. An LLM coder that disagrees with itself cannot
   be trusted to disagree with a human meaningfully.
4. **Do the verbatims contradict the scales?** A persona scoring "Probably
   interested" while writing enthusiastic prose is the same compression the
   `aat_top_box_category` finding pointed at. This is a genuine cross-check
   between two channels of the same panel, needing no external data.

Check 4 is the one to do first. It is cheap and it bears directly on the biggest
open question in the project.

---

## Part C — The driver model, and its precondition

A driver model regresses POSTINT on the ELEMENT ratings and persona attributes
to say which concept elements move intent.

**It must not be built yet, and Phase 2 already established why.** Driver models
and segmentation both assume features that vary and co-vary. Measured on this
panel: knowing Fatal Fury lifts martial-arts fandom **2.45× for humans and
1.08× for ours**, and 11 questions have ≥90% of answers in a single option. Run
on this data a driver model will return weak, unstable coefficients, and it will
read as a modelling failure when the cause is upstream in how the personas were
generated.

So the driver model gets an explicit, measurable precondition:

```
Preconditions, all three, before any model is fitted:
  1. The degeneracy screen (A2) passes for every predictor entering the model.
  2. Test-retest (A1) for the outcome measure is >= 0.85.
  3. The predictor correlation matrix is not near-diagonal -- there is
     structure to find.
```

If those fail, the deliverable of Part C is **the failed precondition report**,
not a model. That is a real result: it says the panel cannot support driver
analysis yet and names what has to change. A model fitted anyway would be worse
than nothing, because its coefficients would be quoted.

When the preconditions do pass, fit it two ways — a regularised regression and a
tree ensemble — and gate on their agreement about which drivers matter, on the
Gate 6 principle.

---

## Part D — What "trustworthy" means on a banner cell

The deliverable that ties this together. Today a banner cell is a bare number.
It should carry its own warrant, and every input below is already computed or
specified above:

| Field | Source | Meaning |
|---|---|---|
| `comparability` | `dim_cuts_wtab` | demographic vs behavioural — *shipped* |
| `reliability` | A1 | this question's test–retest rate |
| `effective_n` | A2 | usable sample after degeneracy |
| `run_spread` | A4 | between-regeneration variance |
| `quota_audit` | A5 | agreement with public benchmarks |
| `bias_flags` | A3 | acquiescence, order, response-set |

A cell then reads: *"38.7%, reliability 0.82, effective n 340, run spread ±2.1pp,
quota audit passed, no bias flags"* — and a reader can tell without asking
whether it will hold. A cell that fails its own checks is **suppressed rather
than shipped with a caveat**, because caveats do not survive being pasted into a
deck.

---

## Sequence

| # | Work | Needs |
|---|---|---|
| 1 | A1 test–retest as a standing gate | nothing — data in hand |
| 2 | A2 degeneracy screen, split by `metric_kind` | nothing |
| 3 | B4 verbatim-vs-scale contradiction | nothing |
| 4 | A5 public quota audit (ACS/GSS) | public data only |
| 5 | A3 negative controls | a questionnaire change |
| 6 | A4 run-to-run variance | panel regeneration |
| 7 | Part D trust fields on every cell | 1–6 |
| 8 | B1–B3 AI verbatim coding + validation | a human-coded sample |
| 9 | Part C driver model | preconditions passing |

Items 1–4 need nothing that is not already available and should start
immediately. Items 5–6 need decisions from whoever generates the personas.
Item 9 may never open, and that is an acceptable outcome.

## Open questions for the research lead

These are unchanged from Phase 2 and still block the most valuable work:

1. **Were persona attributes drawn jointly or independently?** Independent
   field-by-field draws would produce exactly the zero-correlation pattern that
   makes the driver model unfittable.
2. **Was the concept or category named in the generation prompt?** That would
   explain both the 92.5% martial-arts fandom and the near-absence of personas
   unfamiliar with Fatal Fury.
3. **Was this intended as an on-target enthusiast panel or a general-population
   sample?** If the former, nothing is broken — but the behavioural banner
   columns should be dropped, because cutting an all-enthusiast panel by
   enthusiasm cannot inform anything.
4. **What is `aat_top_box_category`?** Its source scale and provenance are
   unknown, and it disagrees with POSTINT on 193 of 329 "Probably" personas.
5. **Is the income floor deliberate?** No persona earns under $35,000. That is a
   generation constraint, not sampling noise.
