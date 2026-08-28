#!/usr/bin/env python3
"""
Emit the full synthetic-vs-human banner comparison as one flat CSV.

One row per comparable cell: question x banner column x answer option, with our
percentage, the human study's percentage, and the gap. This is the artefact for
reading, arguing with, and pasting into a deck — the BigQuery tables
(mart_banner_wtab, and sql/50 when it lands) are the same numbers for machines.

Runs entirely from files in the repo. No credentials, no warehouse. That is
deliberate: anyone can regenerate it and get byte-identical output, and it does
not go stale when a token expires.

What lines up, and what does not
--------------------------------
Both sides are reduced to the same shape before joining:

    (question, banner column, answer option) -> percentage of that column's base

Our side is recomputed from the 12 source CSVs using the same three rules the
pipeline uses (option_code from the LAST numeric prefix per F5; primary_code =
MIN(code) where code < 90 per D9; the standalone 2.1 file beating 2.1X). Their
side comes from ref/wtabs_cells.csv, parsed by tools/extract_wtabs.py.

Rows carry `comparability`, which decides how a gap should be read:

  demographic   the two panels share a quota frame (all 17 columns within
                1.7pp), so a gap here is a real difference in answers.
  behavioural   the column holds a different KIND of group on each side -- ours
                is 92.5% martial-arts fans against their 19.5% -- so a gap
                mixes "different answers" with "different people" and cannot be
                read as either alone.

Usage
-----
    python3 tools/build_comparison_csv.py
        -> out/banner_comparison.csv   every cell
        -> out/banner_summary.csv      one row per question, for a deck
"""

import csv
import importlib.util
import os
import re
import sys
import unicodedata
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
CELLS = "ref/wtabs_cells.csv"
TABLES = "ref/wtabs_tables.csv"
CROSSWALK = "ref/wtabs_crosswalk.csv"
OUT_CELLS = "out/banner_comparison.csv"
OUT_SUMMARY = "out/banner_summary.csv"


def load_validate_local():
    spec = importlib.util.spec_from_file_location("vl", os.path.join(HERE, "validate_local.py"))
    m = importlib.util.module_from_spec(spec)
    sys.argv = ["validate_local"]
    spec.loader.exec_module(m)
    return m


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


OPT_RE = re.compile(r"^\s*\d+\.\s*(\d+)\.\s*(.*)$")
OPT_FALLBACK = re.compile(r"^\s*(\d+)\.\s*(.*)$")


def parse_options(selected):
    """[(code, label)] from a pipe-delimited selection string."""
    out = []
    for opt in (selected or "").split("|"):
        if not opt.strip():
            continue
        m = OPT_RE.match(opt) or OPT_FALLBACK.match(opt)
        if m:
            out.append((int(m.group(1)), m.group(2).strip()))
    return out


# Our (cut_name, cut_value) -> their (banner_group, banner_col).
# Taken from validate_local.PAIRS so the two tools cannot drift apart.
def column_map(vl):
    m = {(cn, cv): (wg, wc) for wg, wc, cn, cv in vl.PAIRS}
    # The Total column is not in PAIRS — validate_local reconciles cut SIZES
    # against the panel total, so it had nothing to compare Total against. Here
    # it is the most important column in the deck, and on the W-Tabs side it
    # carries a blank banner_group.
    m[("TOTAL", "Total")] = ("", "Total")
    return m


def our_side(vl):
    """
    (question_key-ish, cut, option) -> counts, recomputed from the CSVs.

    Keyed on (meta, question_text) rather than the md5 so the output stays
    readable; the crosswalk carries the hash where it is needed.
    """
    personas, _ = vl.load()
    # Re-read raw selections: vl.load() reduces to primary_code and we need the
    # full option list and labels.
    import glob
    rows = []
    for path in sorted(glob.glob(vl.CSV_GLOB)):
        is_x = "2.1X" in os.path.basename(path)
        with open(path, encoding="utf-8-sig", newline="") as fh:
            rd = csv.DictReader(fh)
            idxs = sorted(int(m.group(1)) for c in rd.fieldnames
                          if (m := re.match(r"^Q(\d+)_meta$", c)))
            for row in rd:
                aid = row.get("archetype_id")
                if not aid:
                    continue
                for i in idxs:
                    q = row.get(f"Q{i}_question")
                    if not q or not q.strip():
                        continue
                    rows.append((aid, row.get(f"Q{i}_meta"), q, is_x,
                                 row.get(f"Q{i}_selected")))
    best = {}
    for aid, meta, q, is_x, sel in rows:
        k = (aid, meta, q)
        if k not in best or (best[k][0] and not is_x):
            best[k] = (is_x, sel)

    resp = {k: v[1] for k, v in best.items()}
    cuts = vl.build_cuts(personas, {k: vl.primary_code(v) for k, v in resp.items()})
    return personas, resp, cuts


def their_side():
    """(table_no, banner_group, banner_col, row_label) -> (freq, pct, base)."""
    out = {}
    for r in csv.DictReader(open(CELLS, encoding="utf-8")):
        if r["banner"] != "Ban1" or r["is_sigma"] == "True" or r["is_net"] == "True":
            continue
        try:
            base = int(r["banner_base_n"]) if r["banner_base_n"] else None
        except ValueError:
            base = None
        out[(r["table_no"], r["banner_group"], r["banner_col"], norm(r["row_label"]))] = (
            float(r["freq"]) if r["freq"] else None,
            float(r["pct"]) if r["pct"] else None,
            base,
        )
    return out


def question_tables():
    """
    (meta, item) -> table_no for tables carrying a FULL distribution, i.e. the
    per_item and plain layouts. 48 of the 76 Ban1 tables.
    """
    out = {}
    for t in csv.DictReader(open(TABLES, encoding="utf-8")):
        if t["banner"] != "Ban1" or t["layout"] == "summary":
            continue
        out[(t["meta"], t["marker"])] = t["table_no"]
    return out


def summary_tables():
    """
    meta -> [(table_no, metric_label)] for the summary layout.

    Only 32 of the 76 comparable questions have a full-distribution table. The
    rest appear ONLY inside summary tables, where the marker is a metric
    ("'One of my favorites' Summary Table") and each ROW is a battery item. So
    for those questions the human study publishes one number, not a
    distribution — and dropping them would hide 44 of 76 questions from the
    comparison while the output still looked complete.

    Those questions are emitted with a single option row, the one whose label
    matches the summary's metric.
    """
    out = defaultdict(list)
    for t in csv.DictReader(open(TABLES, encoding="utf-8")):
        if t["banner"] != "Ban1" or t["layout"] != "summary":
            continue
        metric = re.sub(r"\s*Summary Table\s*$", "", t["marker"]).strip().strip("'")
        out[t["meta"]].append((t["table_no"], metric))
    return out


def main():
    for p in (CELLS, TABLES, CROSSWALK):
        if not os.path.exists(p):
            sys.exit(f"ERROR: {p} missing. Run tools/extract_wtabs.py and "
                     f"tools/build_wtab_crosswalk.py first.")

    vl = load_validate_local()
    personas, resp, cuts = our_side(vl)
    theirs = their_side()
    qtab = question_tables()
    stab = summary_tables()
    colmap = column_map(vl)

    xwalk = [r for r in csv.DictReader(open(CROSSWALK, encoding="utf-8"))
             if r["target_class"] == "question"]

    # comparability per cut family, from dim_cuts_wtab's own classification
    DEMOG = {"TOTAL", "GENDER", "QUADRANTS", "AGE BREAKOUT", "MEN AGE DETAIL", "ETHNICITY"}

    out_rows = []
    for x in xwalk:
        meta, qtext = x["our_meta"], x["question_text"]
        table_no = qtab.get((x["wtab_meta"], x["wtab_item"]))
        # Questions with no full-distribution table are compared through the
        # summary tables instead: one metric each, keyed on the item as a row.
        summaries = [] if table_no else stab.get(x["wtab_meta"], [])
        if table_no is None and not summaries:
            continue
        source = "distribution" if table_no else "summary_metric"

        for (cn, cv), (wg, wc) in colmap.items():
            members = [a for a in personas if (cn, cv) in cuts[a]]
            # base: members who answered this question at all
            answered = [a for a in members if resp.get((a, meta, qtext))]
            if not answered:
                continue
            counts, labels = defaultdict(int), {}
            for a in answered:
                for code, lab in parse_options(resp[(a, meta, qtext)]):
                    counts[code] += 1
                    labels[code] = lab
            base = len(answered)

            for code in sorted(counts):
                lab = labels[code]
                if source == "distribution":
                    t = theirs.get((table_no, wg, wc, norm(lab)))
                else:
                    # summary tables: their number sits at (summary table whose
                    # metric == this option label, row = the battery item)
                    t = None
                    for tno, metric in summaries:
                        if norm(metric) == norm(lab):
                            t = theirs.get((tno, wg, wc, norm(x["wtab_item"])))
                            break
                    if t is None:
                        continue
                ours_pct = counts[code] / base
                row = {
                    "meta": meta,
                    "question_text": qtext,
                    "question_key": x["question_key"],
                    "wtab_table": table_no or "",
                    "source": source,
                    "battery_item": x["wtab_item"],
                    "cut_name": cn,
                    "cut_value": cv,
                    "comparability": "demographic" if cn in DEMOG else "behavioural",
                    "option_code": code,
                    "option_label": lab,
                    "ours_n": counts[code],
                    "ours_base": base,
                    "ours_pct": round(ours_pct, 4),
                    "theirs_n": "" if not t or t[0] is None else int(t[0]),
                    "theirs_base": "" if not t or t[2] is None else t[2],
                    "theirs_pct": "" if not t or t[1] is None else round(t[1], 4),
                    "delta_pp": "" if not t or t[1] is None else round((ours_pct - t[1]) * 100, 1),
                    "status": "matched" if t and t[1] is not None else "no_human_counterpart",
                }
                out_rows.append(row)

    os.makedirs("out", exist_ok=True)
    fields = list(out_rows[0].keys())
    with open(OUT_CELLS, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(out_rows)

    # --- per-question summary, Total column only, for a deck ---------------
    summary = []
    seen = set()
    for r in out_rows:
        if r["cut_name"] != "TOTAL" or r["status"] != "matched":
            continue
        k = (r["meta"], r["question_text"], r["option_label"])
        if k in seen:
            continue
        seen.add(k)
        summary.append({
            "meta": r["meta"],
            "battery_item": r["battery_item"],
            "question_text": r["question_text"][:110],
            "option_code": r["option_code"],
            "option_label": r["option_label"],
            "ours_pct": r["ours_pct"],
            "theirs_pct": r["theirs_pct"],
            "delta_pp": r["delta_pp"],
            "ours_base": r["ours_base"],
            "theirs_base": r["theirs_base"],
        })
    summary.sort(key=lambda s: (s["meta"], s["battery_item"], s["option_code"]))
    with open(OUT_SUMMARY, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(summary[0].keys()))
        w.writeheader()
        w.writerows(summary)

    matched = sum(1 for r in out_rows if r["status"] == "matched")
    qs = len({r["question_key"] for r in out_rows})
    print(f"Wrote {OUT_CELLS}   {len(out_rows):,} cells "
          f"({matched:,} with a human counterpart) across {qs} questions")
    print(f"Wrote {OUT_SUMMARY}  {len(summary):,} rows (Total column, per option)")

    dem = [r for r in out_rows if r["status"] == "matched" and r["comparability"] == "demographic"]
    beh = [r for r in out_rows if r["status"] == "matched" and r["comparability"] == "behavioural"]
    for label, rows in (("demographic", dem), ("behavioural", beh)):
        if not rows:
            continue
        ad = sorted(abs(r["delta_pp"]) for r in rows)
        med = ad[len(ad) // 2]
        print(f"  {label:<12} {len(rows):>6,} cells   median |gap| {med:>5.1f}pp   "
              f"within 5pp: {sum(1 for x in ad if x <= 5) / len(ad):.0%}")


if __name__ == "__main__":
    main()
