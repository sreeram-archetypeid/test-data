#!/usr/bin/env python3
"""
Recompute the W-Tabs banner cuts from the 12 source CSVs, independently of
BigQuery, and reconcile them against the human study's own bases.

Why this exists
---------------
docs/MIGRATION_ROADMAP.md parks this script as "an independent Python
recomputation of every gate from the CSVs. Worth building the next time a number
is disputed." A number is now disputed: the human W-Tabs report POSTINT
"Definitely interested" at 44% (351/800) and the delivered banner plan at 45.9%,
while docs/PHASE1_EXPLAINED.md records our mart at 26/398 = 6.5% top box with
T2B at 89.2% against their 92.3%. Near-identical T2B, seven-fold different top
box. Either the pipeline is wrong or the synthetic panel hedges massively, and
nothing downstream is safe until we know which.

It also does a job the warehouse cannot do for us: it validates the *cut
definitions* before they are written into SQL. A banner cut is a claim about who
belongs in a column, and the cheapest test of that claim is whether our 398 land
in the same proportions as their 800 — the two studies share a quota frame, so
demographic columns should agree closely even where answers do not.

This deliberately re-derives everything from the raw CSVs rather than reading
ff_20_curated. An independent recomputation that reuses the thing it is checking
proves nothing.

Faithfulness to Phase 1
-----------------------
Three rules are copied exactly, because getting any of them wrong silently
changes every number:

  option_code    the LAST numeric prefix, not the first. Options arrive as
                 "position. code. label" (F5), so '1. 99. None of the above' is
                 code 99, not code 1.
  primary_code   MIN(option_code) over selections with code < 90. Sentinels are
                 in the base and out of the numerator (D9).
  is_primary_run section 2.1 ran twice for cohorts G.2 and S.1. The standalone
                 file beats the combined 2.1X file, so any query crossing
                 sections must pin one run or it double-counts 198 personas.

Usage
-----
    python3 tools/validate_local.py              # cut reconciliation vs W-Tabs
    python3 tools/validate_local.py --postint    # the disputed POSTINT figure
"""

import argparse
import csv
import glob
import os
import re
import sys
from collections import Counter, defaultdict

# Both delivery folders. Section 1.4 arrived separately, and this script's whole
# value is that it recomputes the warehouse totals from source with no shared
# code -- which it can only do if it reads the same source the warehouse does.
CSV_GLOBS = [
    "Written Descriptions_2026_08_7/*.csv",
    "Written Descriptions_2026_08_18/*.csv",
]
CELLS_PATH = "ref/wtabs_cells.csv"

EXPECTED_PERSONAS = 398
EXPECTED_FACT_ROWS = 41770          # Gate 4: 40,178 in sections 2.x + 1,592 in 1.4

OPT_CODE_RE = re.compile(r"^\s*\d+\.\s*(\d+)\.")
OPT_CODE_FALLBACK_RE = re.compile(r"^\s*(\d+)\.")


def option_codes(selected):
    """Codes from a pipe-delimited selection string, per F5."""
    out = []
    for opt in (selected or "").split("|"):
        if not opt.strip():
            continue
        m = OPT_CODE_RE.match(opt) or OPT_CODE_FALLBACK_RE.match(opt)
        if m:
            out.append(int(m.group(1)))
    return out


def primary_code(selected):
    """Lowest non-sentinel code, or None. Sentinels (>=90) are real answers."""
    codes = [c for c in option_codes(selected) if c < 90]
    return min(codes) if codes else None


def load():
    """
    (personas, responses). responses is keyed (archetype_id, meta, question_text)
    -> primary_code, already reduced to the primary run.
    """
    personas, rows = {}, []
    for path in sorted(p for g in CSV_GLOBS for p in glob.glob(g)):
        stem = os.path.basename(path)
        # The 2.1X files are the combined ones; the standalone 2.1 wins.
        is_x = "2.1X" in stem
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
                    if not q or not q.strip():
                        continue
                    rows.append((aid, row.get(f"Q{i}_meta"), q, is_x,
                                 primary_code(row.get(f"Q{i}_selected"))))

    if len(rows) != EXPECTED_FACT_ROWS:
        sys.exit(f"ERROR: {len(rows)} response rows, expected {EXPECTED_FACT_ROWS} "
                 f"(Gate 4). The local load has drifted from the pipeline.")
    if len(personas) != EXPECTED_PERSONAS:
        sys.exit(f"ERROR: {len(personas)} personas, expected {EXPECTED_PERSONAS}.")

    # is_primary_run: standalone (not 2.1X) beats combined for duplicated keys.
    best = {}
    for aid, meta, q, is_x, code in rows:
        k = (aid, meta, q)
        if k not in best or (best[k][0] and not is_x):
            best[k] = (is_x, code)
    resp = {k: v[1] for k, v in best.items()}
    return personas, resp


# --- persona-attribute cuts -------------------------------------------------

def age_band(raw):
    a = (raw or "").strip()
    m = re.match(r"^(\d{1,2})(\s*\(|$)", a)
    if m:
        v = int(m.group(1))
    else:
        v = {"13-16": 15, "17-24": 21, "25-29": 27, "30-34": 32, "35-39": 37,
             "40-44": 42, "45-54": 49, "55-64": 59}.get(a)
        if v is None:
            return None
    return v


def wtab_age_breakout(v):
    if v is None:
        return None
    return "13-24" if v <= 24 else "25-34" if v <= 34 else "35-44" if v <= 44 else "45-64"


def wtab_ethnicity(raw):
    """
    The W-Tabs collapse race to the three QUOTA groups, which is a different
    grouping from our six-way race_banner: Asian sits with Caucasian and Other
    rather than standing alone.
    """
    r = (raw or "").strip().lower()
    if "latino" in r or "latico" in r or "hispanic" in r:
        return "Hispanic/Latino"
    if "black" in r or "african" in r:
        return "AA/Black"
    return "Caucasian/Asian/Other"


def find_q(resp, meta, needle):
    """The (meta, question_text) whose text contains needle."""
    hits = {q for (_, m, q) in resp if m == meta and needle.lower() in q.lower()}
    if len(hits) != 1:
        return None
    return hits.pop()


def build_cuts(personas, resp):
    """persona -> {(cut_name, cut_value)}, in the W-Tabs' banner shape."""
    ff1 = find_q(resp, "VGFRAN1", "Fatal Fury")
    gfan = {g: find_q(resp, "GFAN1", g) for g in ("Action", "Martial Arts", "Anime")}
    games = find_q(resp, "ACTIVITIES", "play video games")
    theatre = find_q(resp, "ACTIVITIES", "see movies in a theat")
    postint = find_q(resp, "POSTINT", "interested")

    cuts = defaultdict(set)
    for aid, p in personas.items():
        g = (p.get("archetype_gender") or "").strip().title()
        men = g == "Male"
        v = age_band(p.get("archetype_age_range"))
        band = wtab_age_breakout(v)
        gl = "Men" if men else "Women"

        cuts[aid].add(("TOTAL", "Total"))
        cuts[aid].add(("GENDER", gl))
        if v is not None:
            cuts[aid].add(("QUADRANTS", f"{gl} {'<35' if v < 35 else '35+'}"))
            cuts[aid].add(("AGE BREAKOUT", band))
            if men:
                cuts[aid].add(("MEN AGE DETAIL", f"Men {band}"))
        cuts[aid].add(("ETHNICITY", wtab_ethnicity(p.get("archetype_race"))))

        # Fatal Fury familiarity: 1 know a lot, 2 a little, 3 heard of, 4 never.
        c = resp.get((aid, "VGFRAN1", ff1)) if ff1 else None
        if c:
            cuts[aid].add(("FF FAMILIARITY",
                           {1: "Know a lot", 2: "Know a little",
                            3: "Heard of", 4: "Never Heard of"}.get(c, "?")))
            cuts[aid].add(("FF FAMILIARITY",
                           "Total Know" if c in (1, 2) else "Non-Players"))

        for label, q in gfan.items():
            if q and resp.get((aid, "GFAN1", q)) == 1:
                cuts[aid].add(("GENRE FANS", label))

        c = resp.get((aid, "ACTIVITIES", games)) if games else None
        if c:
            cuts[aid].add(("GAMING", "Daily" if c == 1 else "Weekly/Monthly"))

        # F10: punch 6 'Never' is a screen-out on the theatre item and leaves the
        # base entirely, so this family covers 396 personas, not 398. Folding
        # 'Never' into 'Every 2-6 Months' overstates that column — caught by
        # cross-checking against sql/42, which had it right (279 vs 281).
        c = resp.get((aid, "ACTIVITIES", theatre)) if theatre else None
        if c and c <= 5:
            cuts[aid].add(("MOVIEGOING",
                           "Weekly/Monthly" if c <= 3 else "Every 2-6 Months"))

        c = resp.get((aid, "POSTINT", postint)) if postint else None
        if c:
            cuts[aid].add(("POSTINT",
                           {1: "Definitely", 2: "Probably"}.get(c, "Prob/Def Not")))
    return cuts


BASE_TABLE = "1"        # Ban1 Table 1 (AGE), "Base: Total Respondents"


def wtab_bases():
    """
    (banner_group, banner_col) -> base n, from ONE Total Respondents table.

    Pinning the table matters. Base sizes vary per table because routed
    questions are asked of a subset, so sweeping every table and keeping the
    last value silently mixes them — it reported Total as 668 and Men as 397
    instead of 800 and 480, making every demographic gap wrong. Table 1 is
    "Base: Total Respondents", so its header row gives the unreduced base for
    all 42 banner columns.
    """
    if not os.path.exists(CELLS_PATH):
        return {}
    out = {}
    for r in csv.DictReader(open(CELLS_PATH, encoding="utf-8")):
        if r["banner"] != "Ban1" or r["table_no"] != BASE_TABLE or not r["banner_base_n"]:
            continue
        try:
            out[(r["banner_group"], r["banner_col"])] = int(r["banner_base_n"])
        except ValueError:
            pass
    return out


# W-Tabs banner column -> our (cut_name, cut_value).
PAIRS = [
    ("GENDER", "Men", "GENDER", "Men"),
    ("GENDER", "Women", "GENDER", "Women"),
    ("QUADRANTS", "Men <35", "QUADRANTS", "Men <35"),
    ("QUADRANTS", "Men 35+", "QUADRANTS", "Men 35+"),
    ("QUADRANTS", "Women <35", "QUADRANTS", "Women <35"),
    ("QUADRANTS", "Women 35+", "QUADRANTS", "Women 35+"),
    ("AGE BREAKOUT", "13-24", "AGE BREAKOUT", "13-24"),
    ("AGE BREAKOUT", "25-34", "AGE BREAKOUT", "25-34"),
    ("AGE BREAKOUT", "35-44", "AGE BREAKOUT", "35-44"),
    ("AGE BREAKOUT", "45-64", "AGE BREAKOUT", "45-64"),
    ("MEN AGE DETAIL", "Men 13-24", "MEN AGE DETAIL", "Men 13-24"),
    ("MEN AGE DETAIL", "Men 25-34", "MEN AGE DETAIL", "Men 25-34"),
    ("MEN AGE DETAIL", "Men 35-44", "MEN AGE DETAIL", "Men 35-44"),
    ("MEN AGE DETAIL", "Men 45-64", "MEN AGE DETAIL", "Men 45-64"),
    ("ETHNICITY (QUOTA DEFINITIONS)", "Caucasian/Asian/Other", "ETHNICITY", "Caucasian/Asian/Other"),
    ("ETHNICITY (QUOTA DEFINITIONS)", "Hispanic/Latino", "ETHNICITY", "Hispanic/Latino"),
    ("ETHNICITY (QUOTA DEFINITIONS)", "AA/Black", "ETHNICITY", "AA/Black"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Know a lot", "FF FAMILIARITY", "Know a lot"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Know a little", "FF FAMILIARITY", "Know a little"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Heard of", "FF FAMILIARITY", "Heard of"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Never Heard of", "FF FAMILIARITY", "Never Heard of"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Total Know", "FF FAMILIARITY", "Total Know"),
    ("FATAL FURY FAMILIARITY (P3 DOWN @ VGFRAN1)", "Non-Players", "FF FAMILIARITY", "Non-Players"),
    ("GENRE FANS (P1 @ GFAN1)", "Action", "GENRE FANS", "Action"),
    ("GENRE FANS (P1 @ GFAN1)", "Martial Arts", "GENRE FANS", "Martial Arts"),
    ("GENRE FANS (P1 @ GFAN1)", "Anime", "GENRE FANS", "Anime"),
    ("GAMING", "Daily", "GAMING", "Daily"),
    ("GAMING", "Weekly/Monthly", "GAMING", "Weekly/Monthly"),
    ("POSTINT", "Definitely", "POSTINT", "Definitely"),
    ("POSTINT", "Probably", "POSTINT", "Probably"),
    ("POSTINT", "Prob/Def Not", "POSTINT", "Prob/Def Not"),
    ("MOVIEGOING (P1 @ ACTIVITIES)", "Weekly/Monthly", "MOVIEGOING", "Weekly/Monthly"),
    ("MOVIEGOING (P1 @ ACTIVITIES)", "Every 2-6 Months", "MOVIEGOING", "Every 2-6 Months"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--postint", action="store_true",
                    help="just the disputed POSTINT distribution")
    args = ap.parse_args()

    personas, resp = load()
    print(f"Loaded {len(personas)} personas, {len(resp)} primary-run responses "
          f"(from {EXPECTED_FACT_ROWS} rows).")

    if args.postint:
        q = find_q(resp, "POSTINT", "interested")
        dist = Counter(resp.get((a, "POSTINT", q)) for a in personas)
        n = sum(v for k, v in dist.items() if k)
        print(f"\nPOSTINT, all {n} personas (unweighted, primary run):")
        for code in sorted(k for k in dist if k):
            print(f"  code {code}: {dist[code]:4d}  {dist[code]/n:6.1%}")
        tb = dist.get(1, 0)
        print(f"\n  Top box (code 1)   : {tb}/{n} = {tb/n:.1%}")
        print(f"  Top-2 box (1 or 2) : {tb+dist.get(2,0)}/{n} = {(tb+dist.get(2,0))/n:.1%}")
        print(f"\n  Human W-Tabs       : 351/800 = 43.9% top box, 83.5% top-2")
        return

    cuts = build_cuts(personas, resp)
    ours = Counter()
    for s in cuts.values():
        ours.update(s)
    n_ours = len(personas)
    bases = wtab_bases()
    n_them = bases.get(("", "Total"), 800)

    print(f"\nBanner cut reconciliation — our {n_ours} vs their {n_them}\n")
    print(f"  {'cut':<16} {'column':<24} {'ours':>6} {'ours%':>7} "
          f"{'theirs':>7} {'theirs%':>8} {'gap':>7}")
    print("  " + "-" * 78)
    last = None
    for wg, wc, cn, cv in PAIRS:
        o = ours.get((cn, cv), 0)
        t = bases.get((wg, wc))
        if t is None:
            continue
        op, tp = o / n_ours, t / n_them
        if cn != last:
            print()
            last = cn
        flag = "" if abs(op - tp) <= 0.05 else "   <--"
        print(f"  {cn:<16} {cv:<24} {o:>6} {op:>6.1%} {t:>7} {tp:>7.1%} "
              f"{op-tp:>+6.1%}{flag}")


if __name__ == "__main__":
    main()
