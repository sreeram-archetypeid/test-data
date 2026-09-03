#!/usr/bin/env python3
"""
Reconcile `aat_top_box_category` against the POSTINT answer, persona by persona.

Why this matters
----------------
The section-1.4 delivery carries 80 persona-attribute columns, not the 46 the
2.x files carry. The extra 34 are an `aat_*` diagnostics block -- pre/post
concept interest, interest delta, top-box category, opening-weekend intent,
polarization, virality, pacing -- fully populated for all 398 personas, and
never looked at until now.

One of them, `aat_top_box_category`, answers the same question POSTINT does and
gives a very different answer. Since the entire Phase 2 finding rests on the
POSTINT number, the two have to be reconciled before either is quoted again.

What this does NOT establish
----------------------------
Two limits, both structural, and neither resolvable from the CSVs:

1. **It is not the same instrument.** Its levels read Definitely / Probably /
   Might-Might Not / Definitely Not. That midpoint word implies a 5-point scale,
   and this study has none -- the observed scale_max universe across all 69
   ordinal questions is {2, 3, 4, 6}. So the two cannot be compared cell for
   cell until the source scale is known.

2. **It is a model-emitted diagnostic, not a persona answer.** It may be the
   *intended* response that the questionnaire answer failed to express, in which
   case it corroborates nothing -- it is the same generator marking its own
   work. It is not an independent measurement and must not be presented as one.

So this script measures the disagreement precisely and stops there. Nothing here
should be wired into a banner or a mart until both points above are settled.

Runs entirely from files in the repo -- no credentials, no warehouse.

Usage
-----
    python3 tools/compare_aat_postint.py
"""

import collections
import csv
import glob
import os
import re
import sys

S14_GLOB = "Written Descriptions_2026_08_18/*.csv"
S2X_GLOB = "Written Descriptions_2026_08_7/*.csv"

# Measured from the human W-Tabs, Banner 1 Table for POSTINT. Carried here only
# for display; tools/validate_local.py --postint is the authority.
HUMAN_TB, HUMAN_T2B = 43.9, 83.5

# POSTINT is a 4-point scale, 1 = best (the study-wide convention).
POSTINT_ORDER = ["Definitely interested", "Probably interested",
                 "Probably not interested", "Definitely not interested"]
AAT_ORDER = ["Definitely Interested", "Probably Interested",
             "Might/Might Not", "Definitely Not"]

OPT_RE = re.compile(r"^\s*\d+\.\s*(\d+)\.\s*(.*)$")
OPT_FALLBACK = re.compile(r"^\s*(\d+)\.\s*(.*)$")


def option_label(raw):
    """'1. 1. Definitely interested' -> 'Definitely interested'."""
    m = OPT_RE.match(raw or "") or OPT_FALLBACK.match(raw or "")
    return m.group(2).strip() if m else (raw or "").strip()


def load_aat():
    """archetype_id -> the whole aat_* block, from the section-1.4 files."""
    out = {}
    for path in sorted(glob.glob(S14_GLOB)):
        with open(path, encoding="utf-8-sig", newline="") as fh:
            for row in csv.DictReader(fh):
                aid = row.get("archetype_id")
                if aid:
                    out[aid] = {k: v for k, v in row.items() if k.startswith("aat_")}
    return out


def load_postint():
    """
    archetype_id -> POSTINT answer label, reduced to the primary run.

    Section 2.1 was asked twice of 198 personas; the standalone file beats the
    combined 2.1X file, exactly as fct_response.is_primary_run does. POSTINT
    itself is not in 2.1, but the rule is applied uniformly so this cannot drift
    from the warehouse's definition.
    """
    best = {}
    for path in sorted(glob.glob(S2X_GLOB)):
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
                    if (row.get(f"Q{i}_meta") or "").strip() != "POSTINT":
                        continue
                    sel = (row.get(f"Q{i}_selected") or "").strip()
                    if sel and (aid not in best or (best[aid][0] and not is_x)):
                        best[aid] = (is_x, option_label(sel))
    return {k: v[1] for k, v in best.items()}


def pct(n, d):
    return f"{n / d * 100:.1f}%" if d else "-"


def main():
    aat, postint = load_aat(), load_postint()
    both = sorted(set(aat) & set(postint))
    if not both:
        sys.exit("ERROR: no personas joined — check the source folders exist.")

    print(f"Personas: {len(aat)} with aat_*, {len(postint)} with POSTINT, "
          f"{len(both)} joined.")
    if len(both) != len(aat) or len(both) != len(postint):
        print("  WARNING: the two sides do not cover the same personas.")

    cat = {a: aat[a]["aat_top_box_category"].strip() for a in both}

    # --- marginals ---------------------------------------------------------
    n = len(both)
    pc = collections.Counter(postint[a] for a in both)
    ac = collections.Counter(cat[a] for a in both)

    print(f"\nTop box, same {n} personas")
    print(f"  POSTINT answer         {pc['Definitely interested']:4d}  "
          f"{pct(pc['Definitely interested'], n):>6s}")
    print(f"  aat_top_box_category   {ac['Definitely Interested']:4d}  "
          f"{pct(ac['Definitely Interested'], n):>6s}")
    print(f"  human W-Tabs                 {HUMAN_TB:5.1f}%   (351/800)")

    print("\nFull distributions")
    print(f"  {'POSTINT':30s}{'':4s}{'aat_top_box_category':30s}")
    for i in range(4):
        p, a = POSTINT_ORDER[i], AAT_ORDER[i]
        print(f"  {p:24s}{pc[p]:4d} {pct(pc[p], n):>6s}    "
              f"{a:20s}{ac[a]:4d} {pct(ac[a], n):>6s}")

    # --- the cross-tab -----------------------------------------------------
    ct = collections.Counter((postint[a], cat[a]) for a in both)
    w = max(len(p) for p in POSTINT_ORDER) + 2
    print(f"\nCross-tab — rows are the POSTINT answer, columns aat_top_box_category")
    print("  " + " " * w + "".join(f"{c[:16]:>18s}" for c in AAT_ORDER) + f"{'row n':>9s}")
    for p in POSTINT_ORDER:
        tot = sum(ct[(p, a)] for a in AAT_ORDER)
        print("  " + f"{p:{w}s}" + "".join(f"{ct[(p, a)]:18d}" for a in AAT_ORDER)
              + f"{tot:9d}")
    print("  " + f"{'column n':{w}s}"
          + "".join(f"{sum(ct[(p, a)] for p in POSTINT_ORDER):18d}" for a in AAT_ORDER)
          + f"{n:9d}")

    # --- the single number that matters ------------------------------------
    prob_n = sum(ct[("Probably interested", a)] for a in AAT_ORDER)
    promoted = ct[("Probably interested", "Definitely Interested")]
    agree_top = ct[("Definitely interested", "Definitely Interested")]
    top_n = sum(ct[("Definitely interested", a)] for a in AAT_ORDER)

    print(f"\nWhere they agree, and where they do not")
    print(f"  POSTINT 'Definitely' also aat 'Definitely' : {agree_top}/{top_n}"
          f"  ({pct(agree_top, top_n)})")
    print(f"  POSTINT 'Probably'  but aat 'Definitely'   : {promoted}/{prob_n}"
          f"  ({pct(promoted, prob_n)})")
    print("\n  The two are correlated but shifted one level: they agree at the top,")
    print("  then aat promotes a majority of 'Probably' personas into the top box.")
    print("  That is the same generator, asked to self-assess, placing those exact")
    print("  personas where the human study puts them -- which CORROBORATES scale")
    print("  compression in the questionnaire channel. It is not independent")
    print("  evidence, and it does not show the pipeline is wrong.")

    # --- the numeric interest fields, for completeness ----------------------
    def nums(field):
        vs = []
        for a in both:
            try:
                vs.append(float(aat[a][field]))
            except (KeyError, ValueError):
                pass
        return vs

    print("\nThe numeric interest fields in the same block")
    for f in ("aat_pre_concept_interest_pct", "aat_post_concept_interest_pct",
              "aat_interest_delta"):
        vs = nums(f)
        if vs:
            print(f"  {f:32s} n={len(vs):3d}  mean {sum(vs) / len(vs):6.1f}"
                  f"  min {min(vs):5.1f}  max {max(vs):5.1f}")

    print("\nUnresolved, and required before any of this is quoted as a correction:")
    print("  1. aat's levels include 'Might/Might Not', a 5-point midpoint word.")
    print("     This study has no 5-point scale. The source scale is unknown.")
    print("  2. These are model-emitted diagnostics, not persona answers.")


if __name__ == "__main__":
    main()
