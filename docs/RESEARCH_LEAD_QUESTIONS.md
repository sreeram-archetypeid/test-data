# Questions for the research lead — before banner tables are built

**Status:** the BigQuery pipeline is complete and regression-tested. Gates 1–5
green, data-quality suite 35/35. `ff_20_curated` holds 40,178 response rows,
39,490 option rows, 398 personas, 91 questions.

**Why this document exists:** building `mart_banner_read` requires five
decisions that change published percentages. They are research judgements, not
data facts, so they are not being made in code. Everything else is built and
waiting.

---

## First, the good news: the extraction reconciles to your banner plan exactly

Our question inventory, derived independently from the CSVs, matches
`FF_READ_G_BannerPlan_2026-07-19.xlsx` **item for item on every battery**:

| Battery | Banner plan | Our extraction |
|---|---:|---:|
| ELEMENT1 | 15 | 15 |
| VGFRAN1 | 11 | 11 |
| VGFRAN2 | 10 | 10 |
| VGFRAN3 | 10 | 10 |
| GFAN1 | 8 | 8 |
| ACTIVITIES | 6 | 6 |

91 questions total, 36 question groups. Nothing is missing and nothing is
duplicated.

Your banner plan's scale annotations also **independently confirm** a correction
we had derived from the data alone: eight questions whose scale length we had to
infer (GFAN1 ×3 → 4 points, VGFRAN1 ×3 → 4, VGFRAN3 ×1 → 4, ACTIVITIES video
games → 6). All eight match your annotations. That was the single riskiest
inference in the build and it holds.

---

## Q1 — Is READ a subsample of 998, or are files missing?

Your banner plan is computed on **N = 998** (row 11, "Total Sample"; row 6, "18
sample frames"). The READ respondent CSVs contain **398 personas**.

Consequence: the banner plan's cell values **cannot be used to validate our
output** — different base. We can match its *structure* (cuts, metrics, row
order) but not its *numbers*.

**Need to know:** is 398 the correct READ universe, or should we expect more
files? If 998 is right, roughly 60% of respondents are not in the export we
have.

---

## Q2 — Does cohort `.1` / `.2` encode EXPOSURE ORDER?

Your Banner 1 defines nine cuts. We can build eight. `EXPOSURE ORDER`
(columns BA9: "1st Exposure" / "2nd Exposure") has **no source in the CSVs**.

The four cohorts (`G.1`, `G.2`, `S.1`, `S.2`) are the obvious candidate — two
levels per creative, matching two exposure positions — but nothing in the export
confirms it, and a wrong guess produces a banner column that looks right and
means nothing.

**Need to know:** does `.1`/`.2` map to 1st/2nd exposure? If yes it is a
one-line addition. If no, that cut needs a re-export.

---

## Q3 — Is MEAN meaningful on the 15 ELEMENT1 items?

ELEMENT1's scale is `1 = Increases interest, 2 = Decreases, 3 = No change`.
That is a **categorical direction, not a rank** — "No change" sits between the
other two conceptually, not above them.

Your banner plan reports `MEAN` on these anyway (e.g. r505, MEAN = 1.2769).
Our pipeline would reproduce that figure exactly, because the arithmetic is the
same — but agreeing with a figure is not the same as the figure being
interpretable. Averaging *Increases / Decreases / No change* does not produce a
quantity.

The percentages are fine and worth keeping: TB = % increases, BOT = % no change.
It is `MEAN` specifically, on 15 questions, that we would rather not publish
without your sign-off.

**Need to know:** keep MEAN on ELEMENT1 for template consistency, or suppress it?

---

## Q4 — Confirm the theatre item's reduced base and T3B

`ACTIVITIES — See movies in a theater` is annotated in your plan as:

> `(1=Every day … 5=Once a year or less; Never excluded from base)`

and reports a different metric set from its five siblings: `T3B % (P1-P3
monthly+)`, `B2B% (P4-P5)`, `MEAN (1-5, excl. Never)`.

Our model currently treats it like its siblings: 6 points, all codes in base.
So its base and all four box metrics are wrong as built.

**Need to know:** confirm code 6 ("Never") is excluded from the base for this
item only, and that T3B is `codes 1–3`. This is the only question in the study
using T3B, so it needs a bespoke rule.

---

## Q5 — Do sentinel-only respondents count in the banner base?

419 responses have `99. None of the above` as their **only** selection, across
three questions (`Screener 1`, `PLATFORM`, `SOCIAL`). That is a real answer, not
missing data.

Your plan appears to answer this already — `EMPLOY` reports
`% 99. None of the above` as its own row (0.7591), implying sentinels are in the
base and reported. We have defaulted to **include in `n`, exclude from box
numerators**.

**Need to know:** confirm that default.

---

## Resolved by your own documentation — no action needed

Three things we had flagged turn out to be already answered in the banner plan:

1. **The comics item.** Your PROVENANCE NOTE (r697) documents that
   `ACTIVITIES — Read comics/graphic novels/manga` is stored as a bare numeric
   rating with no answer label, and that its direction (1=Every day … 6=Never)
   is inferred from its label-anchored siblings. That matches what we found and
   settles how to treat it.
2. **Screener naming.** `Screener 1` and `Screener 2` in the export are `EMPLOY`
   and `COUNTRY` in the banner plan. A naming crosswalk, not missing data.
3. **The 2.1 / 2.1X reruns.** Your DECISIONS note (r699, Rolfe 2026-07-19) records
   "Read = rerun (b/a) files", which is consistent with our treating them as
   valid replicate runs rather than one being a discarded pilot.

---

## Corrections to `BIGQUERY_MIGRATION_PLAN.md`

Section 2.4's question inventory has three wrong item counts. Measured, and
confirmed against your banner plan:

| Battery | Doc says | Actual |
|---|---:|---:|
| ELEMENT1 | 4 | **15** |
| VGFRAN2 | 1 | **10** |
| VGFRAN3 | 1 | **10** |

The 91-question total in that document is correct; only the per-battery
breakdown is wrong.

---

## Still open from the design doc's Appendix A

1. **G/S = Goyer/Sheridan** — inferred from banner project IDs
   (`FF_READ_G` / `FF_READ_S`), never stated in the CSVs. Confirm.
2. **The `17-24` age band** — 22 personas straddle `13-17` and `18-24`. We
   default to `18-24` and flag them; every banner query has a companion
   sensitivity run excluding them. Confirm or supply exact ages.
3. **VGFRAN1 includes `Wanoo-Bagoo [FOIL]`** — we assume this is a deliberate
   validity foil and keep it in the data, excluded from franchise rollups.
   Confirm.
