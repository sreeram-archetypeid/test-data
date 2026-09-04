# Banner validation — what the comparison covers, and what it cannot

How the synthetic panel's banner is compared, cell for cell, against the human
N=800 study in `Final W Tabs (1)/`. Read this before quoting any number out of
`out/banner_comparison.csv` or `out/banner_wtabs_style.csv`.

## The two artifacts

| File | Shape | Use |
|---|---|---|
| `out/banner_comparison.csv` | long/tidy, one row per cell | filtering, pivoting, joining |
| `out/banner_wtabs_style.csv` | the W-Tabs' own print crosstab | opening side by side with their file |

Both regenerate from files already in the repo, with **no credentials**:

```
python3 tools/extract_wtabs.py          # parse their 4 CSVs -> ref/
python3 tools/build_wtab_crosswalk.py   # their tables -> our question_key
python3 tools/build_comparison_csv.py   # -> out/banner_comparison.csv, banner_summary.csv
python3 tools/build_wtabs_style_csv.py  # -> out/banner_wtabs_style.csv
```

That is deliberate. Anyone can reproduce every figure byte-identically, and
nothing goes stale when an access token expires. The BigQuery marts
(`mart_banner_wtab`, and `sql/50` when it lands) are the same numbers for
machines.

## Reading `banner_wtabs_style.csv`

It reproduces their block structure row for row, so a diff lines up on
structure. Column A carries the row's identity, so that is where the source
goes — each answer option becomes three consecutive rows:

```
Definitely interested [SYN]     ours
Definitely interested [HUM]     the human study's
Definitely interested [GAP]     ours minus theirs, in points
```

Four things to know:

- **`[SYN attr]`** means the value is a persona *attribute*, not an answer the
  persona was asked. It applies to region, ethnicity and education. An attribute
  and an answer are not the same kind of evidence, and the label says which.
- **`NET:` rows** are the union of their indented member rows, not a literal
  label. A NET may differ from the sum of its members by up to 0.5pp per member
  — each member is rounded to a whole percent, so a four-member NET can drift
  ±2.0. That is rounding, not error.
- **A `[SYN]` row with no numbers carries the reason in its label** — "no
  comparable cut", "question not in crosswalk", "no personas in base". A blank
  cell never means a measured zero.
- **The header legend lists every banner column we cannot build.** Currently
  four, all `FATAL FURY FANSHIP`.

## What is comparable, and what is not

`comparability` is carried on every row of `dim_cuts_wtab` and
`mart_banner_wtab` so a consumer cannot read a cell without it.

| Family | Comparability | Measured |
|---|---|---|
| GENDER, QUADRANTS, AGE BREAKOUT, MEN AGE DETAIL, ETHNICITY, REGION | demographic | within 1.7pp |
| FF FAMILIARITY, FF FANSHIP, GENRE FANS, GAMING, MOVIEGOING, POSTINT | behavioural | 22–73pp apart |

The behavioural columns are not "wrong". They hold a **different kind of group**
on each side: the panel was generated on-theme, so cutting it by enthusiasm
selects almost everybody. Those columns compare directionally only, and a
subgroup finding drawn from one means nothing.

## Base rules that change numbers

These are not cosmetic. Each was measured from the source and each moves a base:

- **`is_primary_run`** — section 2.1 was asked twice of 198 personas. Any query
  crossing sections must filter on it or it double-counts them.
- **`base_kind`** — `qre` applies the questionnaire's 17 routing rules, which
  the synthetic panel ignored entirely (F11); `unfiltered` does not. Only
  POLORIENT (338) and ELEMENT2 (347) differ from 398.
- **F10** — the theatre item's punch 6 "Never" is a screen-out, so that
  question's base is 396, not 398.
- **ELEMENT2 is never pooled across concepts.** Its gate leaves Goyer at 171 of
  200 (14.5% excluded) and Sheridan at 176 of 198 (11.1%), so a pooled figure
  averages two differently-gated bases and understates Goyer.
  `tools/build_wtab_banner.sh` asserts zero such rows.
- **Sentinels (option_code ≥ 90)** count in the base and never in a box
  numerator (D9).
- **Scale convention: 1 = best**, and `scale_max` is per question. The observed
  universe across all 69 ordinal questions is {2, 3, 4, 6} — **there is no
  5-point scale anywhere in this study**, so any formula assuming one is wrong
  on every question.

## Region is not derived from the zip code

The delivered `ZIPCODE` answers are corrupt in two different ways at once, so no
single repair rule is correct. 216 of 398 carry only four digits. Measured with
each persona's own stated location as the arbiter, and the 182 full five-digit
zips as a control:

| Reading | Correct |
|---|---:|
| first digit → region, on the 5-digit control | **100.0%** (182/182) |
| 4-digit taken as-is (trailing digit lost) | 78.3% (162/207) |
| 4-digit zero-padded (leading zero lost) | 25.6% (53/207) |

About 150 lost a **trailing** digit (`3030` Atlanta, `8020` Denver, `7708`
Houston) and about 41 lost a **leading zero** (`2108` Boston, `7102` Newark).
Zero-padding the first group yields `03030`, `08020`, `07708` — all real
Northeast zips, so nothing downstream would flag them and the region cut would
read healthy while having relocated 150 personas. The trailing digit is
unrecoverable by any rule.

So region comes from `archetype_location` (389 of 398 resolve; the 9 misses are
empty strings, and all four regions land within 1.4pp of their Table 3), and the
zip is kept verbatim as provenance only. `tools/regions.py` holds both the logic
and the measurement, and emits the same rule as SQL so the two cannot drift.

**This is a defect in the export.** The workaround is sound for region; the raw
files remain lossy and it is worth raising upstream.

## Verification that backs these numbers

| ID | Check |
|---|---|
| V-01 | Every rating-scale column sums to 100% — 12,744 columns, min and max both exactly 1.0000 |
| V-02 | The new per-option row for the top answer equals the previously computed top box across all 10,184 comparable pairs, from two separate code paths |
| V-03 | Question bases intact: POSTINT 398, POLORIENT 338, ELEMENT2 347 |
| V-04 | Zero pooled-qre ELEMENT2 rows |
| IND | `tools/validate_local.py` recomputes the totals from the raw CSVs, sharing no code with the SQL. This is the check that matters most |

## Do not say

- Any absolute interest figure, or any "X% of the audience would…" claim.
- Any subgroup finding drawn from a behavioural banner column.
- Any single accuracy number. "21% of cells within 5 points" mixes differences
  in *answers* with differences in *who is being asked* and means nothing alone.
- `aat_top_box_category` as a correction to POSTINT. It is a model-emitted
  diagnostic rather than a persona's answer, and its levels include a 5-point
  midpoint word this study has no scale for. See `tools/compare_aat_postint.py`.

## The warehouse twin, and the check it made possible

`sql/44_ref_wtabs.sql` lands the human study as three joinable tables
(`ref_wtabs` 99,231 cells, `ref_wtab_tables` 152, `ref_wtab_crosswalk` 340) and
`sql/50_mart_validation.sql` joins them to `mart_banner_wtab`. Build both with:

```
./tools/validate_banners.sh          # 6 gates
./tools/validate_banners.sh --dry-run
```

`mart_validation` is grained by `(question_key, cut_name, cut_value,
option_label, wtab_layout)`. The layout is part of the grain because **a cell
can have two human sources**: ACTIVITIES "play video games" × "Every week" is
printed both in that item's own per-item table and in the "Every week" summary
table. 2,105 cells are duplicated that way and **all 2,105 agree to the printed
digit**, which makes the duplication a free consistency check on their file
rather than a defect in ours. Deduplicating would have discarded that check.

### Why two implementations, and what it caught

The local Python build and the warehouse SQL compute the same comparison from
the same sources while sharing no code. That redundancy is the point, and it
earned its keep: the two disagreed on **196 cells** — 144 POLORIENT and 52
ACTIVITIES. Their numbers matched exactly; only ours differed.

The warehouse was right. `tools/build_comparison_csv.py` was not applying the
questionnaire's base rules at all, so its denominators were inflated:

- **POLORIENT** is not asked of under-18s, so its base is **338**, not 398.
- **ACTIVITIES / theatre** screens out punch 6 "Never" (F10), so its base is
  **396**.

Both are now applied locally too, and the two implementations agree on **all
10,090 overlapping cells, ours and theirs, to six decimal places**. That is
Gate 6, and it is the single strongest piece of evidence that the pipeline is
correct.

```sql
-- the comparison, sanity-checked in one query
SELECT comparability, status, COUNT(*) AS cells
FROM `<project>.ff_30_marts.mart_validation`
GROUP BY 1, 2 ORDER BY 1, 3 DESC;
```

`status` buckets a cell by how far apart the two sides are — `within rounding`
(≤1pp, inside their integer printing), `close` (≤5pp), `diverges` (≤15pp),
`incomparable` (>15pp). Read it alongside `comparability`: a behavioural column
reading `incomparable` is expected and means the two sides hold a different kind
of group, not that a number is wrong.
