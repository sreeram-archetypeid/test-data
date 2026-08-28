#!/usr/bin/env python3
"""
Emit our banner in the human W-Tabs' own print layout, with their numbers
interleaved for comparison.

tools/build_comparison_csv.py produces the same content long/tidy — one row per
cell — which is right for filtering and pivoting but reads nothing like a
banner. This produces the crosstab: the exact block structure of
`Final W Tabs (1)/...Ban1_Pcnt...csv`, so the two files can be opened side by
side and scrolled together.

The block, reproduced row for row:

    #page
    Table N
    <question title>
                ** <marker> **          (per_item and summary tables only)
    <blank>
    Base: ...
    <blank> <blank>
    <banner group row>
    <blank>
    <banner column label row>
    <blank>
    Total <base per column>
    <one row per answer option>
    SIGMA
    #page

Comparison without breaking the layout
--------------------------------------
Column A is the only place a banner carries a row's identity, so the source
goes there rather than in a new column that their file does not have. Each
answer option becomes three consecutive rows:

    Definitely interested [SYN]     our percentage
    Definitely interested [HUM]     the human study's
    Definitely interested [GAP]     ours minus theirs, in points

Every other row — headers, bases, SIGMA — keeps its position, so a diff against
their file lines up on structure.

Columns are ALL of Banner 1's, in their original order, not just the ones we can
build. Where we have no equivalent cut the [SYN] cell is left empty rather than
dropped, so the coverage gap is visible in the output instead of hidden by it.

Usage
-----
    python3 tools/build_wtabs_style_csv.py
        -> out/banner_wtabs_style.csv
"""

import csv
import importlib.util
import os
import re
import sys
import unicodedata
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
WTABS = "Final W Tabs (1)/(305-9113)Arena_FatalFury_ConceptTest_[FFCT061726ES](W)_Ban1_Pcnt(6.22.26).csv"
TABLES = "ref/wtabs_tables.csv"
CROSSWALK = "ref/wtabs_crosswalk.csv"
OUT = "out/banner_wtabs_style.csv"
ENC = "cp1252"


def norm(s):
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^a-z0-9]+", " ", s.lower()).strip()


OPT_RE = re.compile(r"^\s*\d+\.\s*(\d+)\.\s*(.*)$")
OPT_FALLBACK = re.compile(r"^\s*(\d+)\.\s*(.*)$")


def parse_options(selected):
    out = []
    for opt in (selected or "").split("|"):
        if not opt.strip():
            continue
        m = OPT_RE.match(opt) or OPT_FALLBACK.match(opt)
        if m:
            out.append((int(m.group(1)), m.group(2).strip()))
    return out


def load_vl():
    spec = importlib.util.spec_from_file_location("vl", os.path.join(HERE, "validate_local.py"))
    m = importlib.util.module_from_spec(spec)
    sys.argv = ["validate_local"]
    spec.loader.exec_module(m)
    return m


def our_data(vl):
    """personas, raw selections reduced to the primary run, and cut membership."""
    import glob
    personas, rows = {}, []
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
                personas.setdefault(aid, row)
                for i in idxs:
                    q = row.get(f"Q{i}_question")
                    if q and q.strip():
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


def main():
    if not os.path.exists(TABLES):
        sys.exit("ERROR: run tools/extract_wtabs.py and tools/build_wtab_crosswalk.py first.")

    src = [r for r in csv.reader(open(WTABS, encoding=ENC, newline=""))]
    vl = load_vl()
    personas, resp, cuts = our_data(vl)

    colmap = {(cn, cv): (wg, wc) for wg, wc, cn, cv in vl.PAIRS}
    colmap[("TOTAL", "Total")] = ("", "Total")
    rev = {v: k for k, v in colmap.items()}          # their column -> our cut

    # crosswalk: (wtab_meta, wtab_item) -> our (meta, question_text)
    xw = {}
    for r in csv.DictReader(open(CROSSWALK, encoding="utf-8")):
        if r["target_class"] == "question":
            xw[(r["wtab_meta"], r["wtab_item"])] = (r["our_meta"], r["question_text"])

    tables = {(t["banner"], int(t["table_no"])): t
              for t in csv.DictReader(open(TABLES, encoding="utf-8"))
              if t["banner"] == "Ban1"}

    # locate each table block in the source file
    marks = [(int(re.match(r"^Table\s+(\d+)$", r[0]).group(1)), i)
             for i, r in enumerate(src) if r and re.match(r"^Table\s+(\d+)$", r[0].strip())]

    def cell(r, i):
        return r[i].strip() if i < len(r) else ""

    out = []
    covered = skipped = 0

    for n, (tno, start) in enumerate(marks):
        end = marks[n + 1][1] - 1 if n + 1 < len(marks) else len(src)
        meta_row = tables.get(("Ban1", tno))
        if meta_row is None:
            continue

        # find the header rows inside this block
        base_idx = None
        for i in range(start, end):
            if cell(src[i], 0) == "Total" and cell(src[i], 1).replace(",", "").isdigit():
                base_idx = i
                break
        if base_idx is None:
            continue
        label_idx = base_idx - 2
        width = max(len(src[i]) for i in range(start, end))
        labels = [cell(src[label_idx], c) for c in range(width)]
        groups, last = [], ""
        for c in range(width):
            v = cell(src[label_idx - 2], c)
            if v:
                last = v
            groups.append(last)

        layout = meta_row["layout"]
        marker = meta_row["marker"]
        wmeta = meta_row["meta"]

        # Which of our questions does each row of this table correspond to?
        #   distribution -> one question, rows are its options
        #   summary      -> one metric, each ROW is a different question (item)
        if layout == "summary":
            metric = re.sub(r"\s*Summary Table\s*$", "", marker).strip().strip("'")
            qfor = lambda row_label: xw.get((wmeta, row_label))
            optfor = lambda row_label: metric
        else:
            q = xw.get((wmeta, marker))
            qfor = lambda row_label: q
            optfor = lambda row_label: row_label

        # --- emit the block, copying every structural row verbatim ---------
        out.append(["#page"])
        for i in range(start, base_idx):
            out.append(list(src[i]))

        def ours_for(row_label, colidx):
            """our % for this row in this banner column, or '' if unmappable."""
            key = rev.get((groups[colidx], labels[colidx]))
            if key is None:
                return None, None
            target = qfor(row_label)
            if target is None:
                return None, None
            meta, qtext = target
            members = [a for a in personas
                       if key in cuts[a] and resp.get((a, meta, qtext))]
            if not members:
                return None, None
            want = norm(optfor(row_label))
            hit = sum(1 for a in members
                      if any(norm(lab) == want for _, lab in parse_options(resp[(a, meta, qtext)])))
            return hit / len(members), len(members)

        # base row: theirs verbatim, ours beneath
        their_base = list(src[base_idx])
        their_base[0] = "Total [HUM]"
        syn_base = ["Total [SYN]"] + [""] * (width - 1)
        any_col = False
        for c in range(1, width):
            if not labels[c] and not cell(src[base_idx], c):
                continue
            key = rev.get((groups[c], labels[c]))
            if key is None:
                continue
            n_members = sum(1 for a in personas if key in cuts[a])
            syn_base[c] = str(n_members)
            any_col = True
        out.append(syn_base)
        out.append(their_base)

        if not any_col:
            skipped += 1

        # data rows
        emitted = False
        for i in range(base_idx + 1, end):
            lab = cell(src[i], 0)
            if not lab or lab.startswith("#page") or re.match(r"^Table\s+\d+$", lab):
                continue
            if lab.upper() == "SIGMA":
                out.append(list(src[i]))
                continue
            syn = [f"{lab} [SYN]"] + [""] * (width - 1)
            hum = [f"{lab} [HUM]"] + [cell(src[i], c) for c in range(1, width)]
            gap = [f"{lab} [GAP]"] + [""] * (width - 1)
            for c in range(1, width):
                if not labels[c]:
                    continue
                p, _ = ours_for(lab, c)
                if p is None:
                    continue
                syn[c] = f"{p * 100:.0f}%"
                t = cell(src[i], c)
                m = re.match(r"^(-?\d+(?:\.\d+)?)\s*%$", t)
                if m:
                    gap[c] = f"{p * 100 - float(m.group(1)):+.0f}"
                elif t.strip() in ("0", "0 "):
                    gap[c] = f"{p * 100:+.0f}"
                emitted = True
            out.extend([syn, hum, gap])
        if emitted:
            covered += 1

    os.makedirs("out", exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh).writerows(out)
    print(f"Wrote {OUT}  ({len(out):,} rows, {covered} tables with our numbers)")
    print("  Row labels carry [SYN] ours / [HUM] human study / [GAP] difference in points.")
    print("  Blank [SYN] cells are banner columns we cannot build — visible by design.")


if __name__ == "__main__":
    main()
