#!/usr/bin/env python3
"""
Parse the human W-Tabs crosstabs into one long/tidy reference table.

`Final W Tabs (1)/` holds the N=800 *human* study as four CSVs — Banner 1 and
Banner 2, each as frequencies and percentages. These are the figures our
synthetic panel is supposed to track, and they are also the banner *shape* we
are rebuilding `mart_banner_read` into. This script turns them from print-format
crosstabs into rows that can be joined.

Why this is not a five-line csv.reader loop
-------------------------------------------
The files are formatted for paper, not for joining, and three things bite:

1. **Encoding is cp1252**, not UTF-8. A utf-8 decode raises on the smart quotes
   in "'Definitely interested' Summary Table".

2. **Two table layouts**, and several metas use BOTH, so the layout cannot be
   decided per meta — it has to be classified per table:

       per_item    ** See movies in a theater **
                   marker is the battery ITEM, rows are the scale points,
                   distribution sums to 100% and closes with SIGMA
       summary     ** 'Increases my interest' Summary Table **
                   marker is the METRIC, rows are the battery ITEMS,
                   one metric across many items, no SIGMA
       plain       no marker at all — the table IS the question (POSTINT, URG1)

   In per_item the marker holds the item and the row label holds the answer; in
   summary they are the other way round, so misclassifying swaps two key columns
   on every cell of a battery. It reads as a clean parse and yields a wrong join.

   Classification is therefore on SIGMA, not on the marker text — see classify().

3. **Header rows are not at fixed offsets.** Banner 2 carries an extra
   concept sub-group row that Banner 1 does not, and VGFRAN3's title wraps onto
   a second line before its `**` marker. Everything is located by scanning for
   the `Total` base row and working outwards, never by index arithmetic.

Percentages are emitted as proportions (0-1) to match `mart_banner_read.value`,
with the original string kept in `raw_value` so the rounding is auditable.

Usage
-----
    python3 tools/extract_wtabs.py                  # write ref/wtabs_long.csv
    python3 tools/extract_wtabs.py --check          # parse + assert, write nothing
    python3 tools/extract_wtabs.py --table 46       # dump one table, for eyeballing

Output is committed to the repo so every reference number is reviewable in a
diff. Phase 1's rule applies: expectations must be parsed with their provenance
retained, never retyped — hence `source_file` / `source_row` on every row.
"""

import argparse
import csv
import os
import re
import sys
from collections import Counter

WTABS_DIR = "Final W Tabs (1)"

# Two outputs, because one wide file is the wrong shape.
#
# Emitting Freq and Pcnt as separate rows, each repeating source_file (72 chars)
# and question_title (up to 160), produced 198,462 rows and 80MB for what is
# really ~100k numbers — four times the size of the entire source dataset, and
# unreviewable in a diff, which defeats the point of having a reference in the
# repo at all.
#
# So: the table inventory is committed (152 rows — it is what a human actually
# reviews when building the crosswalk), and the cells are pivoted freq-beside-pct
# and left regenerable. The script is the reviewable artifact; the cell file is a
# build output, like the resolved SQL the runners write to mktemp.
TABLES_PATH = "ref/wtabs_tables.csv"   # committed
CELLS_PATH = "ref/wtabs_cells.csv"     # gitignored, regenerated on demand

# (filename, banner, is_pct). Freq and Pcnt are separate files reporting the
# same cells; they are stacked into one table and distinguished by is_pct.
SOURCES = [
    ("(305-9113)Arena_FatalFury_ConceptTest_[FFCT061726ES](W)_Ban1_Freq(6.22.26).csv", "Ban1", False),
    ("(305-9113)Arena_FatalFury_ConceptTest_[FFCT061726ES](W)_Ban1_Pcnt(6.22.26).csv", "Ban1", True),
    ("(305-9113)Arena_FatalFury_ConceptTest_[FFCT061726ES](W)_Ban2_Freq(6.22.26).csv", "Ban2", False),
    ("(305-9113)Arena_FatalFury_ConceptTest_[FFCT061726ES](W)_Ban2_Pcnt(6.22.26).csv", "Ban2", True),
]

ENCODING = "cp1252"

# Measured expectations. Every one of these is a count taken from the files, not
# a guess — the same discipline as the Gate assertions in sql/.
EXPECTED_TABLES = 76
EXPECTED_ROWS = {"Ban1": 2072, "Ban2": 2148}
# per-item tables, summary tables, plain (single-question) tables.
# Identical across all four files, which is itself the check that Freq and Pcnt
# are structurally the same tabulation.
LAYOUT_SPLIT = {"per_item": 20, "summary": 28, "plain": 28}

STAR_RE = re.compile(r"\*\*(.+?)\*\*")
TABLE_RE = re.compile(r"^Table\s+(\d+)\s*$")
# "44%" -> 0.44 ; "0 " -> 0.0 ; "*" -> None (suppressed small base)
PCT_RE = re.compile(r"^(-?\d+(?:\.\d+)?)\s*%$")


def read_rows(path):
    with open(path, encoding=ENCODING, newline="") as fh:
        return [r for r in csv.reader(fh)]


def cell(row, i):
    return row[i].strip() if i < len(row) else ""


def find_tables(rows):
    """Yield (table_no, start, end) for each table block."""
    marks = []
    for i, r in enumerate(rows):
        m = TABLE_RE.match(cell(r, 0))
        if m:
            marks.append((int(m.group(1)), i))
    for k, (no, start) in enumerate(marks):
        end = marks[k + 1][1] if k + 1 < len(marks) else len(rows)
        yield no, start, end


def locate_header(rows, start, end):
    """
    Find the banner header rows by scanning for the base row — the first row
    whose column A is exactly 'Total' and whose column B is an integer.

    Returns (base_idx, label_idx, group_idxs). The label row is the last
    non-blank row above the base row; the group rows are the non-blank rows
    above that (one on Ban1, two on Ban2 — the second is the concept split).
    """
    base_idx = None
    for i in range(start, end):
        if cell(rows[i], 0) == "Total" and cell(rows[i], 1).replace(",", "").isdigit():
            base_idx = i
            break
    if base_idx is None:
        return None, None, []

    label_idx = None
    for i in range(base_idx - 1, start, -1):
        if any(cell(rows[i], c) for c in range(1, len(rows[i]))):
            label_idx = i
            break
    if label_idx is None:
        return base_idx, None, []

    group_idxs = []
    for i in range(label_idx - 1, start, -1):
        if any(cell(rows[i], c) for c in range(1, len(rows[i]))):
            group_idxs.append(i)
        elif group_idxs:
            break
    group_idxs.reverse()
    return base_idx, label_idx, group_idxs


def forward_fill(row, width):
    """Banner group labels are written once per span; carry them rightwards."""
    out, last = [], ""
    for c in range(width):
        v = cell(row, c)
        if v:
            last = v
        out.append(last)
    return out


def classify(marker, has_sigma):
    """
    Decide the layout structurally, from whether the table closes with SIGMA.

    A per-item table's rows are one question's full answer distribution, so they
    sum to 100% and the tabulator prints SIGMA. A summary table's rows are
    independent battery items each carrying one metric, so they do not sum and
    there is no SIGMA. That is a property of the table, not of its wording.

    Do NOT classify on the marker text. The source labels these inconsistently:
    Table 40 says "** 'Definitely interested' Summary Table **" but Table 34 says
    "** I am very much a fan **" for exactly the same shape. Matching on
    "Summary Table" mislabels VGFRAN2 and GFAN1 and silently swaps item with
    metric on every cell of those batteries — it reads as a clean parse and
    produces a wrong join. Caught here only because the Freq/Pcnt reconciliation
    in --check disagreed by ~2%.
    """
    if has_sigma:
        return "per_item" if marker else "plain"
    return "summary" if marker else "plain"


def parse_value(raw, is_pct):
    """Return (value, ok). Percentages become proportions; blanks/'*' become None."""
    s = raw.strip()
    if s in ("", "*", "-", "n/a"):
        return None, False
    if is_pct:
        m = PCT_RE.match(s)
        if m:
            return float(m.group(1)) / 100.0, True
        # bare '0' with trailing space is how these files write a true zero
        if s.replace(".", "", 1).lstrip("-").isdigit():
            return float(s) / 100.0, True
        return None, False
    s = s.replace(",", "")
    if s.lstrip("-").isdigit():
        return float(s), True
    return None, False


def parse_file(path, banner, is_pct):
    rows = read_rows(path)
    out, layouts = [], Counter()

    for table_no, start, end in find_tables(rows):
        title = cell(rows[start + 1], 0)
        meta = title.split(".")[0].strip() if "." in title else title.strip()

        base_idx, label_idx, group_idxs = locate_header(rows, start, end)
        if base_idx is None:
            print(f"  WARN {banner} Table {table_no}: no base row found", file=sys.stderr)
            continue

        # The ** marker sits between the title and the header block, on its own
        # line, after a title that may wrap. Scan the whole pre-header region.
        marker = None
        for i in range(start + 1, base_idx):
            m = STAR_RE.search(cell(rows[i], 0))
            if m:
                marker = m.group(1).strip()
                break

        has_sigma = any(
            cell(rows[r], 0).upper() == "SIGMA" for r in range(base_idx + 1, end)
        )
        layout = classify(marker, has_sigma)
        layouts[layout] += 1

        base_stmt = ""
        for i in range(start + 1, base_idx):
            t = cell(rows[i], 0)
            if t.lower().startswith("base:"):
                base_stmt = t
                break

        width = max(len(rows[i]) for i in range(start, end))
        groups = [forward_fill(rows[i], width) for i in group_idxs]
        labels = [cell(rows[label_idx], c) for c in range(width)]
        bases = [cell(rows[base_idx], c) for c in range(width)]

        # Layout A: marker is the battery item, row label is the answer.
        # Layout B: marker is the metric, row label is the battery item.
        item_from_marker = marker if layout == "per_item" else None
        metric_from_marker = marker if layout == "summary" else None

        for r in range(base_idx + 1, end):
            row_label = cell(rows[r], 0)
            if not row_label or row_label.startswith("#page") or TABLE_RE.match(row_label):
                continue
            is_sigma = row_label.upper() == "SIGMA"
            is_net = row_label.upper().startswith("NET:")

            for c in range(1, width):
                label = labels[c]
                base_n = bases[c]
                if not label and not base_n:
                    continue
                value, ok = parse_value(cell(rows[r], c), is_pct)
                if not ok and not is_sigma:
                    # A blank cell in a tabulated table is a real absence, not a
                    # parse failure — record it so coverage stays honest.
                    pass
                out.append({
                    "source_file": os.path.basename(path),
                    "source_row": r + 1,          # 1-based, matches a text editor
                    "banner": banner,
                    "table_no": table_no,
                    "meta": meta,
                    "question_title": title,
                    "layout": layout,
                    "item": item_from_marker or (row_label if layout == "summary" else ""),
                    "metric_label": metric_from_marker or (row_label if layout != "summary" else ""),
                    "base_stmt": base_stmt,
                    "banner_group": groups[0][c] if groups else "",
                    "banner_concept": groups[1][c] if len(groups) > 1 else "",
                    "banner_col": label,
                    "banner_base_n": base_n,
                    "row_label": row_label,
                    "is_sigma": is_sigma,
                    "is_net": is_net,
                    "is_pct": is_pct,
                    "raw_value": cell(rows[r], c),
                    "value": "" if value is None else repr(value),
                })

    return rows, out, layouts


def col_key(r):
    """
    The banner column's identity.

    `banner_col` alone is NOT unique within a table: 'Weekly/Monthly' appears
    under both GAMING and MOVIEGOING on Banner 1, and 'Men <35' appears under
    both concepts on Banner 2. Grouping on the label alone double-counts those
    columns — it showed up as SIGMA sums of exactly 2.0.
    """
    return (r["banner_group"], r["banner_concept"], r["banner_col"])


def row_key(r):
    """Full identity of one reference cell, less is_pct."""
    return (r["banner"], r["table_no"], r["item"], r["metric_label"],
            r["row_label"]) + col_key(r)


def reconcile(rows):
    """
    Cross-check Freq against Pcnt, and report rather than assert.

    Two facts about these files make a strict equality test wrong:

    1. **Percentages are integers.** '44%' carries +/-0.5pp of quantization, so
       the implied base (freq / pct) scatters wildly — Table 1's Total implies
       anywhere from 756 to 833 against a true 800. Never derive a base that way.

    2. **The printed base row is not always the denominator.** Routed batteries
       (VGFRAN2 fanship is asked only of those aware at VGFRAN1) are percentaged
       on a reduced, per-item base that the table never prints. The recoverable
       denominator is the Freq column's own sum over the distribution.

    So the base-independent check is the one the tabulator itself prints: within
    a single-punch distribution, a column must sum to 100%. Multi-response
    tables ('Southtown Cume') legitimately exceed it, which is why this reports
    a split instead of failing.
    """
    pct = {row_key(r): r for r in rows if r["is_pct"]}
    freq = {row_key(r): r for r in rows if not r["is_pct"]}

    sums, fsums = {}, {}
    for r in rows:
        if r["layout"] == "summary" or r["is_sigma"] or r["is_net"] or not r["value"]:
            continue
        g = (r["banner"], r["table_no"], r["item"]) + col_key(r)
        (sums if r["is_pct"] else fsums)[g] = \
            (sums if r["is_pct"] else fsums).get(g, 0.0) + float(r["value"])

    summing = sum(1 for v in sums.values() if abs(v - 1.0) <= 0.025)
    over = sum(1 for v in sums.values() if v > 1.025)

    # The freq-column-sum is the denominator only where the distribution is
    # exhaustive and single-punch, i.e. where the percentages sum to 100%. On a
    # multi-response table the column sum is a count of mentions, not a base, so
    # testing against it would manufacture failures. Scope the check to the
    # columns where it is meaningful and say so.
    ok = off = 0
    for k, p in pct.items():
        if p["layout"] == "summary" or p["is_sigma"] or p["is_net"] or not p["value"]:
            continue
        g = (p["banner"], p["table_no"], p["item"]) + col_key(p)
        if abs(sums.get(g, 0.0) - 1.0) > 0.025:
            continue
        f = freq.get(k)
        base = fsums.get(g, 0.0)
        if not f or not f["value"] or base <= 0:
            continue
        # 1.0pp. Percentages are stored as integers, so a cell on a base of 11
        # (VGFRAN1 'Never Heard of' x King of Fighters) moves 9pp per respondent.
        # The measured error distribution decays smoothly — 89% inside 0.5pp,
        # ~0.8% past 1pp, all of it on bases under about 20 — so a tighter
        # tolerance flags arithmetic that is in fact correct.
        if abs(float(p["value"]) - float(f["value"]) / base) <= 0.0105:
            ok += 1
        else:
            off += 1

    print(f"\nReconciliation ({len(pct)} pct cells vs {len(freq)} freq cells):")
    print(f"  single-punch columns summing to 100%     : {summing}/{len(sums)}")
    print(f"  of the rest, exceeding 100% (multi-resp) : {over}")
    print(f"  pct == freq / freq-column-sum (+/-1.0pp) : {ok} ok, {off} off")
    return ok, off


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="parse and assert, write nothing")
    ap.add_argument("--table", type=int, help="dump one table and exit")
    args = ap.parse_args()

    if not os.path.isdir(WTABS_DIR):
        sys.exit(f"ERROR: {WTABS_DIR}/ not found — run from the repo root.")

    all_rows, failures = [], []
    for fname, banner, is_pct in SOURCES:
        path = os.path.join(WTABS_DIR, fname)
        if not os.path.isfile(path):
            sys.exit(f"ERROR: {path} not found.")
        raw, parsed, layouts = parse_file(path, banner, is_pct)

        n_tables = sum(layouts.values())
        print(f"{banner} {'Pcnt' if is_pct else 'Freq'}: {len(raw):>5} rows read, "
              f"{n_tables} tables, {len(parsed):>6} cells  {dict(layouts)}")

        if len(raw) != EXPECTED_ROWS[banner]:
            failures.append(f"{fname}: read {len(raw)} rows, expected {EXPECTED_ROWS[banner]}")
        if n_tables != EXPECTED_TABLES:
            failures.append(f"{fname}: {n_tables} tables, expected {EXPECTED_TABLES}")
        if dict(layouts) != LAYOUT_SPLIT:
            failures.append(f"{fname}: layout split {dict(layouts)}, expected {LAYOUT_SPLIT}")

        if args.table:
            for row in parsed:
                if row["table_no"] == args.table:
                    print(row)
            continue
        all_rows.extend(parsed)

    if args.table:
        return

    if failures:
        print("\nASSERTIONS FAILED:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        sys.exit(1)

    print(f"\nAll structural assertions green. {len(all_rows)} cells total.")

    reconcile(all_rows)

    if args.check:
        print("--check — nothing written.")
        return

    write_outputs(all_rows)


def write_outputs(all_rows):
    """Split into a committed table inventory and a pivoted, regenerable cell file."""
    os.makedirs("ref", exist_ok=True)

    # --- table inventory: one row per (banner, table_no) -------------------
    tables, seen = [], set()
    for r in all_rows:
        k = (r["banner"], r["table_no"])
        if k in seen:
            continue
        seen.add(k)
        tables.append({
            "banner": r["banner"],
            "table_no": r["table_no"],
            "meta": r["meta"],
            "layout": r["layout"],
            # per_item -> the marker is the battery item; summary -> the metric;
            # plain -> there is no marker, and metric_label there is just
            # whichever row happened to be first, so it must not be reported.
            "marker": (r["item"] if r["layout"] == "per_item"
                       else r["metric_label"] if r["layout"] == "summary"
                       else ""),
            "base_stmt": r["base_stmt"],
            "question_title": r["question_title"],
        })
    tables.sort(key=lambda t: (t["banner"], t["table_no"]))
    with open(TABLES_PATH, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(tables[0].keys()))
        w.writeheader()
        w.writerows(tables)
    print(f"Wrote {TABLES_PATH}  ({len(tables)} tables)")

    # --- cells: freq beside pct, keyed, no repeated prose ------------------
    CELL_FIELDS = ["banner", "table_no", "item", "metric_label", "row_label",
                   "banner_group", "banner_concept", "banner_col",
                   "banner_base_n", "is_sigma", "is_net", "freq", "pct",
                   "src_freq", "src_pct"]
    cells = {}
    for r in all_rows:
        k = row_key(r)
        c = cells.get(k)
        if c is None:
            c = {f: "" for f in CELL_FIELDS}
            c.update({f: r[f] for f in (
                "banner", "table_no", "item", "metric_label", "row_label",
                "banner_group", "banner_concept", "banner_col",
                "banner_base_n", "is_sigma", "is_net")})
            cells[k] = c
        if r["is_pct"]:
            c["pct"], c["src_pct"] = r["value"], r["source_row"]
        else:
            c["freq"], c["src_freq"] = r["value"], r["source_row"]

    out = sorted(cells.values(), key=lambda c: (c["banner"], c["table_no"],
                                                c["banner_col"], c["row_label"]))
    with open(CELLS_PATH, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=CELL_FIELDS)
        w.writeheader()
        w.writerows(out)
    size_mb = os.path.getsize(CELLS_PATH) / 1e6
    print(f"Wrote {CELLS_PATH}  ({len(out)} cells, {size_mb:.1f}MB — gitignored)")


if __name__ == "__main__":
    main()
