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


# ---------------------------------------------------------------------------
# The six demographic tables
# ---------------------------------------------------------------------------
# Tables 1 (AGE), 2 (GENDER), 3 (ZIPCODE), 4 (ETHNICITY), 75 (EDU) and
# 76 (INCOME) rendered blank because their rows are not answer options in our
# model. Three are now real answers (section 1.4) and three are persona
# attributes; both are tabulated here, and the [SYN] label says which, because
# an attribute is not something a persona was asked.
#
# ZIPCODE's rows are the four Census regions, and region is derived from the
# STATED LOCATION, never from the zip -- see tools/regions.py for why (the
# delivered zips lost a trailing digit in ~150 cases and a leading zero in ~41,
# so no single repair rule is correct and padding fabricates real-but-wrong
# zips). Attribute-derived, because the personas were never asked their region.

AGE_BANDS = [(13, 17, "13-17"), (18, 24, "18-24"), (25, 29, "25-29"),
             (30, 34, "30-34"), (35, 39, "35-39"), (40, 44, "40-44"),
             (45, 54, "45-54"), (55, 64, "55-64")]

INCOME_BANDS = [(0, 19999, "Under $20,000"), (20000, 39999, "$20,000-$39,999"),
                (40000, 69999, "$40,000-$69,999"),
                (70000, 99999, "$70,000-$99,999"),
                (100000, 10**9, "$100,000 or more")]

# Our vocabulary -> the human study's own row label. 'Latico / Hispanic' is a
# typo in the source affecting one persona; mapped rather than lost.
ETHNICITY_MAP = {
    "white / caucasian": "Caucasian",
    "latino / hispanic": "Hispanic",
    "latico / hispanic": "Hispanic",
    "black / african american": "Af-Am",
    "asian or pacific islander": "Asian/Other",
    "asian / pacific islander": "Asian/Other",
}

# 'ged' and 'secondary_education' both land on 'High School graduate': a GED is
# a high-school equivalency and the human questionnaire offers no separate row.
EDU_MAP = {
    "primary_education": "Some High School or less",
    "ged": "High School graduate",
    "secondary_education": "High School graduate",
    "vocational_qualification": "Community College/Associate's Degree",
    "bachelors_degree": "4 Year University/Bachelor's Degree",
    "master_degree": "Master's degree",
    "doctorate_higher": "Doctorate degree",
}

# meta -> whether its values come from an ANSWER or a persona ATTRIBUTE
DERIVED_SOURCE = {"AGE": "answer", "GENDER": "answer", "INCOME": "answer",
                  "ZIPCODE": "attribute", "ETHNICITY": "attribute",
                  "EDU": "attribute"}


def band(value, bands):
    for lo, hi, label in bands:
        if lo <= value <= hi:
            return label
    return None


# "T1 - SHERIDAN" / "T2 - GOYER" -- the marker on a by-concept table.
CONCEPT_RE = re.compile(r"^T[12]\s*-\s*(SHERIDAN|GOYER)$", re.I)

# Why a [SYN] cell is empty. Written into the row label so the file explains
# itself; previously a blank could mean any of these and the reader could not
# tell which.
R_NO_CUT = "no comparable cut"
R_NO_QUESTION = "question not in crosswalk"
R_NO_BASE = "no personas in base"

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


def load_regions():
    spec = importlib.util.spec_from_file_location(
        "regions", os.path.join(HERE, "regions.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def load_vl():
    spec = importlib.util.spec_from_file_location("vl", os.path.join(HERE, "validate_local.py"))
    m = importlib.util.module_from_spec(spec)
    sys.argv = ["validate_local"]
    spec.loader.exec_module(m)
    return m


def our_data(vl):
    """personas, raw selections reduced to the primary run, and cut membership."""
    import glob
    personas, rows, ratings = {}, [], {}
    for path in sorted(p for g in vl.CSV_GLOBS for p in glob.glob(g)):
        is_x = "2.1X" in os.path.basename(path)
        with open(path, encoding="utf-8-sig", newline="") as fh:
            rd = csv.DictReader(fh)
            idxs = sorted(int(m.group(1)) for c in rd.fieldnames
                          if (m := re.match(r"^Q(\d+)_meta$", c)))
            for row in rd:
                aid = row.get("archetype_id")
                if not aid:
                    continue
                # 1.4 rows carry 80 attribute columns against 2.x's 46, the 46
                # being a strict prefix, so whichever is seen first is safe.
                personas.setdefault(aid, row)
                for i in idxs:
                    q = row.get(f"Q{i}_question")
                    if q and q.strip():
                        rows.append((aid, row.get(f"Q{i}_meta"), q, is_x,
                                     row.get(f"Q{i}_selected")))
                    # AGE / ZIPCODE / INCOME are q_type 2: the value is in
                    # `rating`, not `selected`, so the option path never sees
                    # them. Keyed by meta alone -- each appears once per persona.
                    rv = (row.get(f"Q{i}_rating") or "").strip()
                    m = (row.get(f"Q{i}_meta") or "").strip()
                    if rv and m in ("AGE", "INCOME", "ZIPCODE"):
                        try:
                            ratings[(aid, m)] = float(rv)
                        except ValueError:
                            pass
    best = {}
    for aid, meta, q, is_x, sel in rows:
        k = (aid, meta, q)
        if k not in best or (best[k][0] and not is_x):
            best[k] = (is_x, sel)
    resp = {k: v[1] for k, v in best.items()}
    cuts = vl.build_cuts(personas, {k: vl.primary_code(v) for k, v in resp.items()})
    # group_name carries the concept: '3-ARENA-FF-G-test-...' / '...-S-...'.
    # Needed for the by-concept tables (47/48), which split POSTINT by creative
    # rather than by a battery item.
    creative = {a: ("Goyer" if "-G-" in (r.get("group_name") or "") else
                    "Sheridan" if "-S-" in (r.get("group_name") or "") else None)
                for a, r in personas.items()}
    return personas, resp, cuts, creative, ratings


def main():
    if not os.path.exists(TABLES):
        sys.exit("ERROR: run tools/extract_wtabs.py and tools/build_wtab_crosswalk.py first.")

    src = [r for r in csv.reader(open(WTABS, encoding=ENC, newline=""))]
    vl = load_vl()
    personas, resp, cuts, creative, ratings = our_data(vl)
    regions = load_regions()

    def derived(meta, aid):
        """This persona's value for one of the six demographic tables."""
        if meta == "AGE":
            v = ratings.get((aid, "AGE"))
            return band(v, AGE_BANDS) if v is not None else None
        if meta == "INCOME":
            v = ratings.get((aid, "INCOME"))
            return band(v, INCOME_BANDS) if v is not None else None
        if meta == "GENDER":
            for _, _, qt in [k for k in resp if k[0] == aid and k[1] == "GENDER"]:
                for _, lab in parse_options(resp[(aid, "GENDER", qt)]):
                    return lab
            return None
        if meta == "ZIPCODE":
            # region from the stated location, never from the zip
            return regions.region_of(personas[aid].get("archetype_location"))[0]
        if meta == "ETHNICITY":
            return ETHNICITY_MAP.get(
                (personas[aid].get("archetype_race") or "").strip().lower())
        if meta == "EDU":
            return EDU_MAP.get(
                (personas[aid].get("archetype_education_level") or "").strip().lower())
        return None

    colmap = {(cn, cv): (wg, wc) for wg, wc, cn, cv in vl.PAIRS}
    colmap[("TOTAL", "Total")] = ("", "Total")
    rev = {v: k for k, v in colmap.items()}          # their column -> our cut

    # crosswalk: (wtab_meta, wtab_item) -> our (meta, question_text)
    #
    # 'concept' rows are loaded alongside 'question' rows. Tables 47/48 are
    # POSTINT split by creative -- their marker names the concept ("T1 -
    # SHERIDAN"), not a battery item -- so they resolve to the same question as
    # any other POSTINT table and are then restricted to that creative. Loading
    # only 'question' is why those two tables rendered blank.
    xw, concept_of = {}, {}
    for r in csv.DictReader(open(CROSSWALK, encoding="utf-8")):
        if r["target_class"] in ("question", "concept"):
            xw[(r["wtab_meta"], r["wtab_item"])] = (r["our_meta"], r["question_text"])
        if r["target_class"] == "concept":
            m = CONCEPT_RE.match(r["wtab_item"])
            if m:
                concept_of[(r["wtab_meta"], r["wtab_item"])] = m.group(1).title()

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
    unbuildable = set()          # banner columns we have no equivalent cut for

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

        # A NET row is a roll-up of the INDENTED rows that follow it:
        #
        #     NET: Weekly/Monthly   61%
        #       Every week          12%
        #       Every month         49%
        #
        # The old code matched the literal label "NET: Weekly/Monthly" against
        # our option labels, found nothing, and wrote 0% -- a confident wrong
        # number, not a gap. Table 5 read -61 where the truth is about -31.
        # Membership is structural (leading whitespace), so read it from the
        # source rather than hardcoding which options belong to which NET.
        net_members, cur = {}, None
        for i in range(base_idx + 1, end):
            raw = src[i][0] if src[i] else ""
            if not raw.strip() or raw.strip().upper() == "SIGMA":
                cur = None
                continue
            if raw.strip().upper().startswith("NET:"):
                cur = raw.strip()
                net_members[cur] = []
            elif cur and raw[:1].isspace():
                net_members[cur].append(raw.strip())
            else:
                cur = None

        # Tables 47/48 split POSTINT by concept, so restrict to that creative.
        want_creative = concept_of.get((wmeta, marker))

        # One of the six demographic tables? Its rows are banded values or
        # attribute labels rather than answer options, so it takes the derived
        # path below instead of the crosswalk/option path.
        dsrc = DERIVED_SOURCE.get(wmeta) if layout == "plain" else None

        # Which of our questions does each row of this table correspond to?
        #   distribution -> one question, rows are its options
        #   summary      -> one metric, each ROW is a different question (item)
        # optfor returns a LIST of option labels: a plain row matches one, a NET
        # row matches the union of its members.
        if layout == "summary":
            metric = re.sub(r"\s*Summary Table\s*$", "", marker).strip().strip("'")
            qfor = lambda row_label: xw.get((wmeta, row_label))
            optfor = lambda row_label: [metric]
        else:
            q = xw.get((wmeta, marker))
            qfor = lambda row_label: q
            optfor = lambda row_label: net_members.get(row_label.strip()) or [row_label]

        # --- emit the block, copying every structural row verbatim ---------
        out.append(["#page"])
        for i in range(start, base_idx):
            out.append(list(src[i]))

        def ours_for(row_label, colidx):
            """(percent, base_n, reason) for this row in this banner column.

            percent is None when we cannot produce a number; reason then says
            why, so a blank cell is never mistaken for a measured zero.
            """
            key = rev.get((groups[colidx], labels[colidx]))
            if key is None:
                return None, None, R_NO_CUT

            if dsrc:
                members = [a for a in personas
                           if key in cuts[a] and derived(wmeta, a) is not None
                           and (want_creative is None
                                or creative[a] == want_creative)]
                if not members:
                    return None, None, R_NO_BASE
                want = {norm(x) for x in optfor(row_label)}
                hit = sum(1 for a in members if norm(derived(wmeta, a)) in want)
                return hit / len(members), len(members), None

            target = qfor(row_label)
            if target is None:
                return None, None, R_NO_QUESTION
            meta, qtext = target
            members = [a for a in personas
                       if key in cuts[a] and resp.get((a, meta, qtext))
                       and (want_creative is None or creative[a] == want_creative)]
            if not members:
                return None, None, R_NO_BASE
            # Union over the row's labels: one for a plain row, several for a
            # NET. Correct for multi-punch too, where members can overlap.
            want = {norm(x) for x in optfor(row_label)}
            hit = sum(1 for a in members
                      if any(norm(lab) in want
                             for _, lab in parse_options(resp[(a, meta, qtext)])))
            return hit / len(members), len(members), None

        # base row: theirs verbatim, ours beneath
        their_base = list(src[base_idx])
        their_base[0] = "Total [HUM]"
        syn_base = [f"Total [SYN{' attr' if dsrc == 'attribute' else ''}]"] + [""] * (width - 1)
        any_col = False
        for c in range(1, width):
            if not labels[c] and not cell(src[base_idx], c):
                continue
            key = rev.get((groups[c], labels[c]))
            if key is None:
                continue
            n_members = sum(
                1 for a in personas
                if key in cuts[a]
                and (want_creative is None or creative[a] == want_creative)
                and (not dsrc or derived(wmeta, a) is not None))
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
            syn = [""] * width
            hum = [f"{lab} [HUM]"] + [cell(src[i], c) for c in range(1, width)]
            gap = [""] * width
            reasons = set()
            for c in range(1, width):
                if not labels[c]:
                    continue
                p, _, why = ours_for(lab, c)
                if p is None:
                    if why == R_NO_CUT:
                        unbuildable.add((groups[c], labels[c]))
                    else:
                        reasons.add(why)
                    continue
                syn[c] = f"{p * 100:.0f}%"
                t = cell(src[i], c)
                m = re.match(r"^(-?\d+(?:\.\d+)?)\s*%$", t)
                if m:
                    gap[c] = f"{p * 100 - float(m.group(1)):+.0f}"
                elif t.strip() in ("0", "0 "):
                    gap[c] = f"{p * 100:+.0f}"
                emitted = True
            # A row that produced nothing says why, in its own label. A blank
            # used to mean "no cut", "no question" or "no base" indifferently.
            note = f" — {'; '.join(sorted(reasons))}" if reasons and not any(syn[1:]) else ""
            # An attribute is not an answer, and a reader must not have to know
            # which is which. Tag it where the row's identity lives.
            tag = " attr" if dsrc == "attribute" and any(syn[1:]) else ""
            syn[0] = f"{lab} [SYN{tag}]{note}"
            gap[0] = f"{lab} [GAP]"
            out.extend([syn, hum, gap])
        if emitted:
            covered += 1

    # Legend first, so the file explains its own gaps without a reader having
    # to come back and ask. Columns are listed once here rather than marked in
    # every cell, which would bury the numbers under thousands of markers.
    legend = [
        ["# Synthetic vs human banner — W-Tabs Banner 1 print layout"],
        ["# [SYN] ours   [HUM] human study (N=800)   [GAP] ours minus theirs, in points"],
        ["# A [SYN] row that produced no numbers carries the reason in its label."],
        ["# NET: rows are the union of their indented member rows, not a literal label."],
        ["# [SYN attr] means the value is a persona ATTRIBUTE, not an answer the persona"],
        ["#   was asked. Applies to ZIPCODE/region, ETHNICITY and EDU. Region is derived"],
        ["#   from the stated location, never from the zip code (see tools/regions.py)."],
    ]
    if unbuildable:
        legend.append([f"# {len(unbuildable)} banner columns have no comparable cut on our side "
                       "— their [SYN] cells are empty by design:"])
        for g, l in sorted(unbuildable):
            legend.append([f"#     {g} / {l}" if g else f"#     {l}"])
    legend.append([])

    os.makedirs("out", exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="") as fh:
        csv.writer(fh).writerows(legend + out)
    print(f"Wrote {OUT}  ({len(out):,} rows, {covered} tables with our numbers)")
    print("  Row labels carry [SYN] ours / [HUM] human study / [GAP] difference in points.")
    print("  Blank [SYN] cells are banner columns we cannot build — visible by design.")


if __name__ == "__main__":
    main()
