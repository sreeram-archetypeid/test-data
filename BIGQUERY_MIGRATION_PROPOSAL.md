# Moving the Fatal Fury Concept Test into BigQuery

### A proposal

**Prepared:** 2026-08-17
**Covers:** the READ (Written Descriptions) study — 398 personas, 12 files
**Companion document:** `BIGQUERY_MIGRATION_PLAN.md` (the technical build spec)

---

## In one paragraph

We have twelve CSV files holding a synthetic concept test, and a set of Excel banner plans
describing the analysis that was done by hand. Today the data is shaped for *reading*, not for
*querying* — one row per persona, with up to 298 columns, and question answers packed into
strings. This proposal describes moving that data into BigQuery in a shape that can be
queried, reproducing the existing banner tables automatically, and then doing three analyses
that the manual process cannot do at all. Estimated effort is **7–11 working days**. The
single biggest gain is that **17,301 open-ended responses**, which the current banner plans
explicitly leave untabulated, become countable.

This document is numbered to match the technical plan — proposal §4 corresponds to plan §4,
and so on. Where you want the SQL, the plan has it.

---

## 2. What we actually have

### The study

Four groups of synthetic personas answered a concept test about a Fatal Fury live-action
movie. Two script treatments were tested:

| Group | Script | Personas |
|---|---|---:|
| G.1 | Goyer | 100 |
| G.2 | Goyer | 100 |
| S.1 | Sheridan | 98 |
| S.2 | Sheridan | 100 |
| | **Total** | **398** |

Each persona carries **46 profile attributes** — age, income, occupation, but also
psychographics, purchasing behaviour, adoption category, a written persona summary, and a
psychometric vector. Each then answered a questionnaire split into three blocks of 20, 35 and
36 questions.

Across all of it: **91 distinct questions**, grouped under **36 question codes**, producing
**40,178 individual answers**.

### One thing that isn't what it looks like

Four of the twelve files are named `2.1X`. It would be reasonable to assume these are
duplicates and delete them. **They are not.**

The `2.1X` files are combined files carrying the first question block for *two* groups at
once. Because a standalone file also exists for one of those groups, two of the four groups
answered the first block **twice** — the same personas, the same twenty questions, on two
separate occasions.

The answers differ:

| | Agreement between the two runs |
|---|---:|
| Numeric ratings | 60% identical |
| Multiple choice | 84% identical |
| Written responses | **0% identical** |

**We propose keeping both runs.** Deleting one would discard real information; keeping both
turns an accident of the export into a free measurement of *how stable these synthetic
personas actually are*, which is exactly the kind of evidence a synthetic-panel methodology
needs in front of a sceptical audience.

The cost of that decision is one rule everybody has to follow: because two groups answered
block 1 twice, any analysis crossing question blocks must pin a single run or it will
double-count 198 personas. The build handles this with a flag on every row — see §7.

### How it's shaped today

Every file is **wide**. One row per persona, then the same seven columns repeated for every
question:

```
archetype_id | ...45 more profile columns... | Q1_question | Q1_meta | Q1_type |
Q1_rating_label | Q1_rating | Q1_selected | Q1_qual | Q2_question | Q2_meta | ...
```

The practical problem: **the question number is a position, not an identity.** The key
concept-interest question `POSTINT` is `Q29` in one file and `Q7` in another. Any analysis has
to know where each question physically sits in each file, which is why the current process
runs through hand-built Excel banner plans.

---

## 3. What's wrong with the data today

We profiled all twelve files rather than sampling. Eleven distinct issues need handling. Four
of them will silently corrupt results if missed — those are marked **critical**, meaning the
pipeline produces plausible-looking numbers that are wrong.

| Issue | What it is | Why it matters |
|---|---|---|
| **Embedded line breaks** — *critical* | 8,957 answer fields contain line breaks. A 100-persona file spans 501 physical lines. | Loaded naively, every file shatters into fragments. Fails loudly, so it gets caught — but it stops the load dead. |
| **The number prefix** — *critical* | Answers look like `1. 1. Increases my interest`. This reads as a duplicated code. It isn't — it's `position. code. label`. | They match 39,071 times out of 39,490, so reading the first number seems to work. In **419 cases they diverge** — all "None of the above", true code 99. Reading the first number turns those into ordinary scale values and corrupts averages for entire questions. |
| **Multi-answer questions packed into one cell** — *critical* | Nine questions let people pick several options, all crammed into one string separated by `\|` | 2,663 responses affected. Counting "how many chose Discord" is impossible until this is unpacked. Worse, applying top-box scoring to a pick-list produces meaningless numbers that look valid. |
| **Inconsistent ages** — *critical* | 31 different formats: bands (`30-34`), exact ages (`15`), and hybrids (`21 (17-24)`) | Gender and age are the primary banner cuts. 81 personas sit in a `17-24` band that straddles two reporting buckets and cannot be assigned without a judgement call. |
| Inconsistent income | Some are single values (`$95,000`), some are ranges (`$65,000 - $75,000`) | Income is a banner cut; it needs to be numeric |
| Gender casing | `Male`, `Female`, and 4 rows of `MALE` | Would create a spurious third category |
| Curly apostrophes | `Don't` with a typographic apostrophe | Splits categories that should group together |
| Filenames with dashes and spaces | `3-ARENA-FF-G-gr1-2.2 — Results-c.csv` | Breaks cloud storage paths |
| Scores stored as text | NPS is a string, not a number | Can't be averaged until converted |
| Sentinel codes | 419 "None of the above" responses at code 99 | Must be excluded from averages, not treated as a high score |
| Mixed prefix formats | One question uses both formats *in the same column* | The parser has to handle each value individually, not per-question |

### The age decision we need signed off

81 personas are recorded as `17-24`. The reporting buckets are `13-17` and `18-24`. That band
straddles both, and there is no exact age to fall back on.

**Our proposal:** assign them to `18-24`, flag every one as imputed, and run every headline
number twice — once with them, once without. If the two runs disagree materially we escalate
rather than publish. It's a small population (20% of the sample), but it sits in the youngest
cut, which is usually the most scrutinised.

---

## 4. What we propose to build

Four layers, each with one job:

| Layer | What it holds | Who touches it |
|---|---|---|
| **Raw** | An exact, untouched copy of the twelve files | Pipeline only |
| **Staging** | The same data reshaped and cleaned | Pipeline only |
| **Curated** | The organised model — personas, questions, answers | **Analysts and models** |
| **Marts** | Finished outputs — banner tables, coded verbatims | **Reports and dashboards** |

The rule that makes this worth doing: **nothing reads Raw except Staging.** Analysts bind to
Curated and Marts. That boundary is what lets AUDIO and VIDEO be added later without anybody's
existing queries changing.

### On "chunking" the data

This word covers three different things, and they deserve different answers.

**Splitting the wide files into a sensible structure — this is the real work.** One row of 291
columns becomes one persona record plus 35 answer records. After this, "what's the top-box on
concept interest" is a filter on a question code, not knowledge of which column number that
question occupies in which file.

**Loading in batches — one file at a time.** The three question blocks have different column
counts, so they need separate handling. Loading them together would fail, and would also
destroy the record of which file each answer came from — which is precisely what identifies
the repeat runs.

**Physically splitting the table for performance — we recommend against it.**

This deserves a straight answer rather than a default. The whole dataset is about **19.5 MB**.
Partitioning a table this small would create partitions of a few hundred rows each, and
because BigQuery bills a minimum per partition scanned, it would likely cost *more* and scan
*more*, not less. We propose **clustering only** — which is free, has no minimum-size penalty,
and gives real benefit on the columns actually filtered on. We'd revisit only when AUDIO and
VIDEO land and the table is orders of magnitude larger.

---

## 5. Getting the data in

Three steps, roughly half a day.

1. **Copy the twelve files to cloud storage**, renaming them to remove the em-dashes and
   spaces that break storage paths.
2. **Load every column as text.** Deliberately — we do not let BigQuery guess types. Guessing
   would type the same column differently across files and produce a schema that silently
   disagrees with itself. Types get applied in the next layer where the rules are visible and
   testable.
3. **Check the counts before going further.** 596 + 398 + 398 = 1,392 rows. If it isn't exact,
   we stop.

Two settings are non-negotiable: allow line breaks inside quoted fields (or every file
shatters), and reject the whole load on any bad row. The dataset is small enough that a
rejected row is a bug, not noise — we want it to fail loudly rather than quietly drop data.

---

## 6. Organising it

Four tables, replacing twelve inconsistent files.

| Table | Grain | Rows |
|---|---|---:|
| **Personas** | One row per persona | 398 |
| **Questions** | One row per distinct question | 91 |
| **Question options** | Every answer option available | 334 |
| **Runs** | One row per source file | 12 |

The personas table keeps all 46 original attributes untouched, and *adds* cleaned versions
alongside — normalised gender, a proper age band, income as numbers, NPS as a number and a
band. Nothing is overwritten. The original value always survives next to the cleaned one, so
any cleaning decision can be audited or reversed later.

The question-options table is where the scale for each question is worked out — how many
points it has, which code is the best answer, and critically **whether it's a pick-list rather
than a scale.** Nine of the questions let people choose multiple answers, and those must never
receive top-box or average scoring. Getting this wrong is the difference between a real number
and a meaningless one.

---

## 7. Reshaping wide into long

This is the heart of the migration.

**Before** — one row per persona, 291 columns, question identity buried in column names:

```
persona_A | ...profile... | Q29_question="how interested…" | Q29_selected="1. 1. Very"
```

**After** — one row per persona per question:

| persona | question code | question | answer code | answer | is this the primary run? |
|---|---|---|---|---|---|
| persona_A | POSTINT | how interested… | 1 | Very interested | yes |

Every answer becomes addressable. The result is **40,178 rows** — every answer, from every
persona, including both repeat runs.

Two things get resolved at this point:

**The repeat-run flag.** Every row is marked as primary or not. Where a persona answered a
question twice, one run is picked deterministically. Analysts filter on that flag and the
double-counting problem disappears without them having to know it existed.

**Multi-answer unpacking.** The packed strings are exploded into a second table with one row
per chosen option — **39,490 rows**. This is what makes "how many people chose Discord"
answerable.

We then check four numbers before anything downstream is built: 40,178 answers, 398 personas,
91 questions, 39,490 chosen options. All four were measured from the source files, so they're
exact targets, not estimates.

---

## 8. Proving it's right

Sixteen automated checks run after every rebuild. Every one of them encodes a defect we
actually found in this data — they're regression tests, not hypotheticals.

They fall into three groups:

**Did everything arrive?** Row counts, persona counts, question counts, per-group counts.

**Did the cleaning work?** No persona missing an age band. No answer label still carrying a
stray number prefix. Income ranges the right way round. Every open-ended question has text;
every closed question has an answer.

**Did the subtle traps stay caught?** These matter most, because they fail quietly:

- Exactly 419 sentinel "None of the above" responses. **If this reads zero, the number-prefix
  bug has come back** — the parser has reverted to reading position instead of code, and
  averages are being silently corrupted.
- Exactly nine pick-list questions.
- Pick-lists returning *blank* rather than *false* for top-box. Blank is skipped in counting;
  false is counted as a miss. The difference silently understates every percentage.

The point of pinning exact numbers rather than ranges is that a future change either matches
or it doesn't. There's no room to talk yourself into "close enough".

---

## 9. Reproducing the banner tables

The existing banner plans specify, for every question, six metrics — base size, top box,
top-two box, bottom-two box, bottom box, and mean — across seven audience cuts. That's what
gets built by hand today.

We propose generating this automatically, as **two tables rather than one**:

**Scale questions** get the six standard metrics. This is the bulk of the questionnaire.

**Pick-list questions** get percentage-selecting-each-option instead, over a base of
respondents. These percentages sum to more than 100% — correctly. Your own banner plans
already say so, annotating nine rows with *"multi-select: percentages can sum >100%"*.

Keeping these separate is deliberate. Forcing them into one table is exactly what produces an
"average" of a question like *"which words describe this character"* — 19 unranked options
where a respondent picks three. That number would look perfectly valid on a slide and mean
nothing.

To validate, we check the pick-list percentages against figures measured from source. On
average respondents chose 3.10 social platforms, 3.05 genre descriptors, 2.97 character
words, 1.44 viewing companions. If any of those comes back as exactly 1.00, the unpacking
silently failed and we know before publishing.

Once built, this runs in seconds instead of days, for any cut, on demand.

> **A caveat to carry into any output.** The banner plans were written against a sample of
> 998 across all three modalities. The READ files contain 398. Today's numbers will not
> reconcile to the banner plan totals, and any output should say so plainly.

---

## 10. What becomes possible

Reproducing the existing tables is the floor, not the point. Three things become available
that the manual process cannot do.

### The headline: what actually drives interest in this movie?

Crosstabs show association one cut at a time. They can tell you martial-arts fans are more
interested. They cannot tell you whether that's *because* they're martial-arts fans, or
because martial-arts fans skew male and young and it's really age doing the work.

We propose modelling concept interest directly against persona attributes and behaviours, so
the drivers can be **ranked while holding everything else constant** — and compared between
the Goyer and Sheridan scripts. That's a clean comparison: same questionnaire, same personas,
different creative.

**How we'd do it:** three models, in order of value.

**1. A driver model.** Predicts top-box interest from demographics, genre fandom, franchise
familiarity, gaming behaviour and psychographics, then reports which factors matter most and
in which direction. Answers "what moves the needle, and is it different for each script?"

> **An honest caveat:** 398 personas is a small training set. This is a driver-ranking and
> hypothesis-generating tool, not a predictive one. We'd report the ranking and direction, and
> treat predictive accuracy as a sanity check — if the model can't separate interested from
> uninterested at all, the ranking isn't trustworthy and we'd say so. This constraint
> disappears if AUDIO and VIDEO arrive and the sample approaches 998.

**2. A segmentation model.** The data already ships with hand-authored persona types. We'd
cluster the personas independently on their actual answers and check whether the authored
types reproduce. If they line up, that's evidence the persona design is behaviourally sound.
If they don't, that's a finding worth knowing — it means the labels aren't showing up in the
behaviour.

**3. Automated coding of the open-ended responses.** This is the largest single gain.

There are **17,301 written responses** in this dataset — averaging 176 characters, on what
people liked, disliked, would improve, and why they answered as they did. Your banner plans
mark these rows *"verbatims not tabulated here"*, because hand-coding 17,301 responses is
weeks of work.

BigQuery can read every one of them and assign a theme and sentiment in a single pass. Those
codes then feed back into the driver model as inputs — so "people who mentioned wanting a
grounded story" becomes a factor you can measure interest against.

That closes the loop between the qualitative and quantitative sides of the study, which is
the thing the current process structurally cannot do.

*Prerequisite:* this needs an AI connection enabled in the BigQuery project. We'd pilot on one
question, hand-check 100 responses against human coding, and only then run the full set.

### A fourth thing, free

Because we're keeping both repeat runs rather than deleting one, we can report **how
consistently the same persona answers the same question twice**. The baselines are already
measured: 60% on ratings, 84% on multiple choice, 0% on written answers.

Questions where personas are unstable are questions where the numbers deserve a caveat. That's
a credibility asset when presenting synthetic data to an audience inclined to doubt it — and
it costs nothing extra, because the data is already there.

---

## What we need from you

Three decisions and one dependency:

1. **Confirm G and S mean Goyer and Sheridan.** Inferred from the banner plan project codes;
   not stated anywhere in the data itself.
2. **Sign off the age rule** for the 81 personas in the ambiguous `17-24` band.
3. **Confirm both repeat runs are valid** — as opposed to one being a discarded pilot. This
   determines which run is treated as primary.
4. **`EXPOSURE ORDER` cannot currently be built.** It's specified as a banner cut in the plans,
   but nothing in the CSV files records exposure order. If that cut is needed, the data has to
   come from somewhere.

One open question worth flagging: **the banner plans assume 998 respondents; the files contain
398.** Either READ is roughly a 40% subsample, or files are missing. Worth resolving before
anyone compares these outputs to the existing decks.

---

## Effort and sequence

| Phase | What | Days |
|---|---|---|
| 1 | Land the data, verify counts | 0.5 |
| 2 | Reshape, clean, build the model, all checks green | 1–2 |
| 3 | Reproduce the banner tables | 1–2 |
| 4 | Driver model, segmentation, verbatim coding | 2–3 |
| 5 | Compare against the human study | 2–3 |
| | **Total** | **7–11 days** |

Phases 1–3 deliver everything the manual process does today, automatically. Phase 4 is where
the new capability lands. Phase 5 is optional and can follow later.

Running costs are negligible — the dataset is small enough that storage and queries are
effectively free. The only meaningful cost is the AI coding of 17,301 verbatims, which is
priced per volume of text and which we'd estimate from a pilot before committing.

---

*Technical detail, SQL, table definitions and the full check list are in
`BIGQUERY_MIGRATION_PLAN.md`, numbered to match this document.*
