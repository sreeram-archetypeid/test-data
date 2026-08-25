# Phase 1 explained — what was built, and why it looks like this

A plain-English walkthrough of the whole Phase 1 pipeline: what each BigQuery
dataset is for, what the words *staging*, *dimension*, *fact*, *curated* and
*mart* actually mean, and exactly what was executed to get there.

This is the teaching document. For terse technical reference see
`docs/PHASE1_ARCHITECTURE.md`; for the defect log see `docs/PHASE1_RUNBOOK.md`
and `docs/QUESTIONNAIRE_FINDINGS.md`; for what happens next see
`docs/MIGRATION_ROADMAP.md`.

---

## 1. What we started with

Twelve CSV files in `Written Descriptions_2026_08_7/`. They are exports from a
synthetic-panel run of the ARENA / Fatal Fury concept test — AI personas reading
a movie concept and answering a questionnaire.

The files are **very wide and hard to query**. One file has 298 columns. A single
row is one persona's entire questionnaire, laid out sideways:

| archetype_id | archetype_age_range | … 44 more attributes … | Q1_question | Q1_meta | Q1_type | Q1_rating_label | Q1_rating | Q1_selected | Q1_qual | Q2_question | … |
|---|---|---|---|---|---|---|---|---|---|---|---|

Every question occupies a **repeating block of 7 columns**. The files come in
three shapes, because the questionnaire was fielded in three sections:

| Section | Files | Rows | Questions | Total columns |
|---|---|---:|---:|---|
| 2.1 | 4 | **596** | 20 | 46 + 20×7 = **186** |
| 2.2 | 4 | 398 | 35 | 46 + 35×7 = **291** |
| 2.3 | 4 | 398 | 36 | 46 + 36×7 = **298** |

Sections 2.2 and 2.3 are tidy: four files, one cohort each, 100 + 100 + 98 + 100
= 398 personas. **Section 2.1 is not**, and this is the single most confusing
thing about the source data:

| File | Rows | Cohorts inside |
|---|---:|---|
| `G-gr1-2.1X` | 200 | G.1 **and** G.2 |
| `G-gr2-2.1` | 100 | G.2 |
| `S-gr1-2.1` | 98 | S.1 |
| `S-gr2-2.1X` | 198 | S.1 **and** S.2 |
| | **596** | |

The two `X` files are **combined** files holding two cohorts each. So cohorts
**G.2 and S.1 appear twice** — once inside an `X` file and once in a standalone
file — while G.1 and S.2 appear only once. That is 198 personas who answered
section 2.1's 20 questions **twice**, and it is why section 2.1 has 596 rows for
398 personas.

You cannot ask "what was the top-box score on purchase intent?" of a table like
this, because purchase intent is column `Q29` in section 2.2 and column `Q1` in
section 2.3. **The entire job of Phase 1 is turning that shape into a shape you
can ask questions of.**

Two other things came with the data and turned out to be essential:

- `ARENA_Fatal Fury Concept Test_Programming 061926.docx` — the **questionnaire**
  (the "QRE"). This is the specification. Reading it properly is what uncovered
  the biggest finding in the project (F11).
- `Support Files/FF_*_BannerPlan_*.xlsx` — the **banner plans**, which define
  exactly which numbers a report is supposed to contain.

---

## 2. The core idea: four datasets, each with one job

Think of a professional kitchen.

| Kitchen | Our dataset | Job |
|---|---|---|
| Delivery crates, unopened | `ff_00_raw` | proof of what arrived |
| Prep station — washing, chopping | `ff_10_staging` | reshape into something usable |
| Labelled containers you cook from | `ff_20_curated` | the trusted ingredients |
| The plated dish | `ff_30_marts` | shaped for whoever is eating |

Nobody cooks straight out of a delivery crate, and nobody re-chops an onion that
is already prepped. Each stage has one job, and each stage only ever reads from
the one before it.

**One rule matters more than the rest: nothing queries `ff_00_raw` except
`ff_10_staging`.** If an analyst starts reaching into raw, every cleaning rule we
wrote becomes optional, and two people asking the same question get two answers.

*Where the analogy breaks:* crates get thrown out. `ff_00_raw` is kept forever
and never edited — it is the evidence that lets us prove what the source
actually said, months later, when someone disputes a number.

---

## 3. The vocabulary, properly

These five words do a lot of work. Here is what each actually means.

### Grain — the most important concept here

**The grain of a table is what one row means.** Say it out loud before you query
anything:

- `dim_archetype` — "one row per **persona**" (398 rows)
- `fct_response` — "one row per **persona, per run, per question**" (40,178 rows)
- `fct_response_option` — "one row per **option a persona selected**" (39,490)

Get the grain wrong and you count the same person twice. This is not theoretical:
it caused three separate errors during Phase 1. The plan document said 81
personas had an imputed age; the real figure is **22 personas**, because 81 counts
row-*occurrences* across the 12 files and each persona appears in 3–4 of them
(F2). Same data, different grain, wrong number.

### Staging — the prep station

A **staging** table is intermediate work. Its job is to get data from the shape
it arrived in into the shape you need. It is:

- **disposable** — delete it and re-run, nothing is lost
- **not for analysis** — no one should build a report on a staging table
- **allowed to be ugly** — this is where the messy reshaping happens

Ours does exactly one hard thing: turns 1 row × 298 columns into 36 rows × 10
columns. That operation is called an **unpivot** (wide → long).

### Dimension (`dim_`) — the nouns

A **dimension** table describes *a thing that exists*. Who, what, when, where.

- Few rows, many descriptive columns
- One row per real-world thing, with a stable ID
- Changes rarely

`dim_archetype` is the personas. `dim_question` is the questions. If you can
point at it and say "that's a *thing*", it's a dimension.

### Fact (`fct_`) — the events

A **fact** table records *something that happened* or *was measured*.

- Many rows, mostly IDs plus numbers
- One row per event
- Grows as more data arrives

`fct_response` is "this persona answered this question in this run". That is an
event. It happened 40,178 times.

### Star schema — how dims and facts fit together

Facts in the middle, dimensions around the outside, joined by ID:

```
              dim_archetype (who answered)
                      |
   dim_run  ──── fct_response ──── dim_question (what was asked)
 (which file)         |
              dim_question_option (what the answer choices were)
```

It's called a star because of the shape. The point is that descriptive text is
stored **once** in a dimension rather than repeated 40,178 times in the fact
table — so fixing a persona's income band is a one-row edit, not a mass update.

### Curated — the contract

`ff_20_curated` is the layer everything else is allowed to trust. Every cleaning
rule has been applied, every column has a real type, every number has been
checked against the source.

Calling it a **contract** is deliberate: analysts, dashboards and models all bind
to these table and column names. Upstream layers can be rebuilt freely; change
something here and you break other people's work.

### Mart — the serving layer

A **mart** is a subset reshaped for one specific audience. Not new information —
the same information, pre-arranged so a report doesn't have to do the work.

`mart_banner_read` holds one row per number that would appear in a banner table.
It exists because building a banner from `fct_response` means writing the same
awkward aggregation every time, and the fifth person to write it will get it
subtly wrong.

---

## 4. Follow one answer all the way through

The clearest way to see the pipeline is to watch a single answer move through it.

Persona `6031a21e-7f50-4dcb-b55f-108be6ba7a1a` — from
`3-ARENA-FF-G-gr2-2.3 — Results-c.csv`. She is 55–64, female, $140,000 household
income, White, married, children grown and out of the home, NPS 8. She read the
**Goyer** concept, in cohort **G.2**.

She was asked *"how interested would you be in seeing this new, live-action movie
in a theater…"* — the question tagged `POSTINT`, purchase intent, the single most
important measure in the study.

### Stage 0 — in the CSV

One cell, in a 298-column row:

```
Q1_selected = "3. 3. Probably not interested"
```

### Stage 1 — `ff_00_raw.raw_read_s23`

Loaded verbatim. Every column is `STRING`, including numbers. Nothing is parsed,
nothing is fixed, nothing is dropped. Two columns are added: `_source_file` and
`_loaded_at`.

**Why all-STRING:** if BigQuery tries to guess types on load, one malformed cell
fails the whole file, and you find out at 2am. Load everything as text, then
convert deliberately where you can see the rule and test it.

### Stage 2 — `ff_10_staging.stg_response`

The 7-column block becomes its own row, and the answer gets parsed:

| column | value |
|---|---|
| `archetype_id` | `6031a21e-…` |
| `run_id` | `3-ARENA-FF-G-gr2-2.3 — Results-c` |
| `meta` | `POSTINT` |
| `question_text` | *You will now read the Concept. Based on the concept…* |
| `selected_options` | `[{option_code: 3, option_label: "Probably not interested"}]` |

Note what happened to `"3. 3. Probably not interested"`. There are **two** numeric
prefixes. The first is the option's *position* in the list; the second is its
*code*. They usually agree — which is why it is easy to get wrong. They disagree
419 times in this dataset, and every time, the second number is `99`, the code for
"None of the above".

Reading the first number made those 419 sentinel answers invisible and inflated
the scale length on three questions. **We take the last prefix** (F5). This is the
single most consequential parsing decision in the pipeline.

### Stage 3 — `ff_20_curated.fct_response`

Joined to the persona and question dimensions, and the measures derived:

| column | value | meaning |
|---|---|---|
| `primary_code` | `3` | lowest non-sentinel code selected |
| `scale_max` | `4` | POSTINT is a 4-point scale |
| `is_primary_run` | `TRUE` | this is the row to use |
| `is_in_qre_base` | `TRUE` | the questionnaire did intend to ask her this |
| `creative` | `Goyer` | which concept she read |
| `cohort_code` | `G.2` | which group |

Then `v_response_metrics` — a **view**, so it computes on read rather than
storing anything — adds the box metrics:

| flag | value | why |
|---|---|---|
| `is_tb` (top box) | `FALSE` | code 3, not 1 |
| `is_t2b` (top-2) | `FALSE` | 3 is not in {1, 2} |
| `is_bot` (bottom) | `FALSE` | 3 is not 4 |
| `is_b2b` (bottom-2) | `TRUE` | 3 **is** in {3, 4} |

Scale convention comes from the banner plans: **1 = best**. So low codes are good
news, and `scale_max` differs per question — 2, 3, 4 or 6 in this study, never 5.

### Stage 4 — `ff_30_marts.mart_banner_read`

She now contributes to POSTINT's numbers in every cut she belongs to — these
eight demographic ones, plus any behavioural cut she qualifies for (heavy gamer,
genre fan, knows Fatal Fury; not POSTINT top-box, since she answered 3):

| cut_name | cut_value |
|---|---|
| TOTAL | Total |
| GENDER | Female |
| AGE | 55-64 |
| GENDER_AGE | F 55-64 |
| RACE | White Non-Hisp |
| INCOME | $125K+ |
| RELATIONSHIP | MARRIED/PARTNERED |
| PARENT | Parents |

In each, she is +1 to the base and +1 to the bottom-2-box numerator, and nothing
to top box. Across all 398 personas, POSTINT comes out at **26 top box (6.5%)**
and **355 top-2 (89.2%)**.

One more detail worth noticing: she is in cohort **G.2**, one of the two cohorts
whose section 2.1 was run **twice**. So for the 20 questions in section 2.1 she
has *two* rows in `fct_response`, with `is_primary_run` marking one of them. Any
query that crosses sections and forgets `WHERE is_primary_run` double-counts her
and 197 others.

---

## 5. The datasets, table by table

### `ff_00_raw` — landed exactly as it arrived

| Table | Rows | Columns | Grain |
|---|---:|---:|---|
| `raw_read_s21` | 596 | 186 | one persona-run of section 2.1 |
| `raw_read_s22` | 398 | 291 | one persona of section 2.2 |
| `raw_read_s23` | 398 | 298 | one persona of section 2.3 |

596 rather than 398 in section 2.1 because cohorts G.2 (100) and S.1 (98) each
appear twice: 398 + 100 + 98 = 596.

**Use for:** proving what the source said. Nothing else.
**Never** query it from a report.

### `ff_10_staging` — reshaped and parsed

| Table | Rows | Purpose |
|---|---:|---|
| `stg_response_s21` | 11,920 | 596 × 20, unpivoted |
| `stg_response_s22` | 13,930 | 398 × 35, unpivoted |
| `stg_response_s23` | 14,328 | 398 × 36, unpivoted |
| `stg_response` | **40,178** | the three unioned, options parsed, types cast |

**Use for:** debugging a parse. Rebuild freely.
**Don't** build reports here — no dimension joins, no derived measures.

### `ff_20_curated` — the contract

| Table | Rows | Grain | What it is |
|---|---:|---|---|
| `dim_archetype` | 398 | persona | the 46 source attributes plus cleaned age, gender, income, NPS band, and the banner cut columns |
| `dim_run` | 12 | source file | makes the twice-run files explicit rather than implicit |
| `dim_question` | 91 | question | question text, `meta` tag, and `metric_kind` — the classification that decides which measures are legal |
| `dim_question_option` | 334 | question × option | the answer choices, with `scale_max` and sentinel flags |
| `dim_qre_base` | 9 | routed question | the questionnaire's skip rules, written down as data |
| `fct_response` | **40,178** | persona × run × question | **the analysis contract.** Bind here. |
| `fct_response_option` | 39,490 | one selected option | the right grain for multi-select pick-lists |
| `v_response_metrics` | *view* | same as `fct_response` | box metrics, computed on read |

`metric_kind` deserves a note, because it prevents a whole class of nonsense:

| kind | Questions | Legal measures |
|---|---:|---|
| `ordinal_scale` | 54 | top/bottom box, mean |
| `categorical` | 15 | percentages per option — **not** a mean |
| `multi_select` | 9 | incidence per option |
| `single_option` | 2 | count only |
| `numeric_rating` | 1 | mean rating |
| `open_end` | 10 | nothing yet — Phase 4 |

Without this, "top box" gets computed on *"which social media apps do you use"*,
where option 1 is a category ID, not a rank. Before the gate existed, 2,037 rows
were being counted as "top box" on questions where the phrase has no meaning.

### `ff_30_marts` — the serving layer

| Table | Grain | What it is |
|---|---|---|
| `dim_archetype_cuts` | persona | behavioural cut flags — heavy gamer, genre fan, knows Fatal Fury, POSTINT top-box |
| `mart_banner_read` | base × creative × question × cut × metric | one row per banner cell |
| `dq_results` | assertion × run | append-only log of every data-quality run |

`mart_banner_read` has one property worth understanding: it emits **both bases**.

- `base_kind = 'qre'` — only the people the questionnaire would actually have
  asked
- `base_kind = 'unfiltered'` — every answer the panel produced

That exists because of the largest finding in the project. The questionnaire
routes **17** questions behind earlier answers ("if you said you wouldn't see it,
what put you off?"). **The synthetic panel enforced none of that routing** — all
398 personas answered everything. So 398 people answered both "what did you
like?" (asked only of interested respondents) and "what put you off?" (asked only
of uninterested ones), which overlap for just one answer option.

Of those 17, **9** have gates we can reconstruct from data we actually hold —
those 9 are the rows in `dim_qre_base`, and between them they account for **532
persona-answers that should never have existed** (676 rows, because one of them
sits in the twice-run section). The remaining 8 are routed on things the export
does not record.

Nothing was deleted. Every row carries a flag, every banner declares which base
it used, and the two are always available side by side (F11).

---

## 6. What was actually executed, step by step

Eight commands, in order. Each one refuses to run if configuration is missing,
and exits non-zero if any check fails.

| # | Command | What it did | Gate |
|---|---|---|---|
| 1 | `./tools/slugify_upload.sh` | renamed the 12 CSVs to safe names (the originals contain em-dashes and spaces, which break BigQuery load URIs) and uploaded to GCS | 12 objects, exact names |
| 2 | `./tools/land_raw.sh` | loaded the 3 raw tables, all columns STRING | **Gate 1** — 596/398/398 = 1,392 |
| 3 | `./tools/shape_staging.sh` | unpivoted wide → long, parsed the option strings, cast types | 40,178 rows + 11 assertions |
| 4 | `./tools/build_curated_dims.sh` | built the 4 dimension tables | **Gates 2 / 2b / 3** — 49 assertions |
| 5 | `./tools/build_metric_model.sh` | classified every question by `metric_kind`, built `fct_response_option` | **Gate 5** — 26 assertions |
| 6 | `./tools/build_fct.sh` | built `fct_response` and the metric view, applied the questionnaire's routing | **Gates 4 + 6** — 30 assertions |
| 7 | `./tools/build_marts.sh` | built the banner tables, both bases | 22 structural checks |
| 8 | `./tools/run_dq.sh` | ran the standing data-quality suite | 44 assertions |

**185 assertions in total, all green.** Every expected value was measured from
the source CSVs *before* the SQL was written — so a mismatch is always a pipeline
bug, never a wrong expectation. (That discipline was tested repeatedly: fourteen
real defects were caught this way.)

### How the code is organised, and why

```
tools/gen_*.py     Python that WRITES SQL
sql/*.sql          the generated + hand-written SQL (committed, reviewable)
tools/*.sh         bash that RUNS the SQL and checks the result
```

Three reasons for the split:

1. **The SQL is committed.** You review in VS Code exactly what ran against
   BigQuery — not a template you have to expand in your head.
2. **Generators eliminate typo classes.** `dim_archetype` projects 46 named
   columns. A typo in a hand-typed 46-name list is easy to make and hard to spot,
   so `gen_dim_archetype.py` reads the names out of the real CSV header and fails
   loudly if the 12 files disagree.
3. **Credentials never enter git.** Committed SQL carries `${PROJECT_ID}` and
   `${DS_*}` placeholders; real values live only in `config.env`, which is
   gitignored. Every runner **refuses to execute** if any placeholder survives
   substitution.

---

## 7. What to use going forward

**Bind to `ff_20_curated.fct_response`** for anything analytical, joined to the
dimensions. That is the contract, and it is the table every gate protects.

**Use `v_response_metrics`** instead of writing top-box arithmetic yourself. It
already knows that `scale_max` varies per question and that box metrics are
illegal on 37 of the 91 questions.

**Use `fct_response_option`** for the 9 multi-select questions. `primary_code`
keeps only the lowest-numbered pick, so reading it on a pick-list silently
discards most of the answer.

**Use `mart_banner_read`** for anything report-shaped, and always state which
`base_kind` you used.

**Three habits that prevent real errors:**

1. **`WHERE is_primary_run`** on any query crossing sections — otherwise 198
   personas count twice.
2. **Say the grain out loud** before writing a number down. Persona-grain and
   row-grain numbers are both correct and are not the same.
3. **`WHERE is_in_qre_base`** when you want figures comparable to a real fielded
   survey. It is `TRUE` for every unrouted question, so it is always safe to
   apply.

**Never query `ff_00_raw` outside the staging layer.** Every cleaning rule lives
downstream of it.

**Extending to AUDIO and VIDEO:** the `modality` column already exists and is
currently always `'READ'`. The generators read real CSV headers, so new files
need a config entry rather than new code. What each new modality *does* need is
its own set of measured gate numbers — that is deliberate, and it is the work.

---

## 8. The fourteen defects, in one place

All were found by checking the plan document and the data against each other,
and all now carry a permanent regression guard.

| | Finding | Consequence had it shipped |
|---|---|---|
| F1 | `SELECT *` union across 291- and 298-column tables | query would not compile |
| F2 | imputed-age count was row-grain, not persona-grain | 81 vs the true 22 |
| F3 | 3 type-1 rows have no verbatim | a NOT NULL assumption would fail |
| F4 | `dim_run` needed the replicate made explicit | silent double-counting |
| F5 | option prefix is `position. code.`, not a doubled code | 419 sentinels invisible, 3 scales inflated |
| F6 | income has 8 formats, not 2 | 8 personas with no income |
| F7 | verbatim/rating column semantics | mis-typed columns |
| F8 | `scale_max` must come from the battery, not the question | 606 rows mis-flagged as bottom box |
| F9 | `ELEMENT1` is categorical — its options rotate | a mean computed over rotated labels |
| F10 | the theatre item screens out "Never" | wrong base on one question |
| F11 | **the panel ignored the questionnaire's routing entirely** | 532 persona-answers that should never have existed |
| F12 | the panel also violated the qualifying screener | panel-fidelity issue, documented |
| F13 | `archetype_race` was never normalised | 7 blanks, a typo, two spellings of Asian |
| F14 | the routing gate lands unevenly on the two creatives | comparing creatives on `ELEMENT2` would understate Goyer |

F11 is worth reading in full (`docs/QUESTIONNAIRE_FINDINGS.md`). The clue was
that the data was *too complete*: 40,178 is exactly rows × questions, with no
gaps. A routed survey always has gaps. **The absence of missing data was the
symptom.**
