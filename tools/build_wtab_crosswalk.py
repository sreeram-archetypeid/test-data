#!/usr/bin/env python3
"""
Build the W-Tabs -> our-model crosswalk, so their cells can be joined to ours.

§12 of BIGQUERY_MIGRATION_PLAN.md says this mapping "cannot be automated
reliably — the wording differs. Budget real time for it". That is half right.
The table titles carry the meta code as a literal prefix ("POSTINT. Based on
the concept you just read..."), so meta is mechanical. What is not mechanical is
the battery item, because our question_text embeds the item in a sentence while
the W-Tabs give it bare:

    ours    How do you feel about the Martial Arts genre of movies/TV series?
    W-Tabs  ** Martial Arts **

So this script generates candidate matches and grades its own confidence. Every
row lands in ref/wtabs_crosswalk.csv with a match_method and a needs_review flag;
review the flagged ones, not all 152 tables.

Six classes of target, because the two studies do not have the same shape
------------------------------------------------------------------------
1. `question`  — maps to one of our 91 question_keys. The response-data
                 comparison, and what mart_banner_wtab must reproduce. 76 rows.

2. `open_end`  — our q_type 1. The W-Tabs tabulate these, our banner mart
                 excludes them by design and Phase 4 codes them, so there is no
                 counterpart to join yet. 249 rows, of which HIGHLIGHT is 242:
                 its "items" are individual story sentences, which is verbatim
                 coding rather than a banner row.

3. `concept`   — the ** slot holds the creative, not an item (POSTINT tables
                 47/48). Maps to our `creative` column.

4. `derived`   — a net or cume column ('Southtown Cume'), computable but not a
                 question.

5. `archetype` — AGE, GENDER, ETHNICITY, INCOME and EDU are *questions* in the
                 human study but *persona attributes* in ours: they live on
                 dim_archetype, not fct_response, and have no question_key.
                 These validate our banner CUT DEFINITIONS rather than any
                 answer, which makes them the quota reconciliation — the
                 cheapest early check that our 398 sit in the same frame as
                 their 800.

6. `ours_only` — our questions with no W-Tabs table, each with a reason. Never
                 dropped: a silent drop would read as agreement.

Coverage closes at 76 + 8 open-end + 7 ours-only = 91, and every battery maps
1:1 with no question_key reused: ACTIVITIES 6/6, ELEMENT1 15/15, GFAN1 8/8,
VGFRAN1 11/11, VGFRAN2 10/10, VGFRAN3 10/10.

question_key is reproduced exactly as sql/11_stg_response.sql computes it:
TO_HEX(MD5(CONCAT(meta, '||', question_text))) over the RAW, untrimmed strings,
so this script's keys join directly to dim_question without BigQuery.

Usage
-----
    python3 tools/build_wtab_crosswalk.py            # write ref/wtabs_crosswalk.csv
    python3 tools/build_wtab_crosswalk.py --report   # print coverage, write nothing
"""

import argparse
import csv
import glob
import hashlib
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict

CSV_GLOB = "Written Descriptions_2026_08_7/*.csv"
TABLES_PATH = "ref/wtabs_tables.csv"
CELLS_PATH = "ref/wtabs_cells.csv"
OUT_PATH = "ref/wtabs_crosswalk.csv"

EXPECTED_QUESTIONS = 91          # Gate 3
EXPECTED_METAS = 36

# Class 2. A judgement, so it is written out explicitly rather than inferred:
# these are the W-Tabs metas whose counterpart is a dim_archetype column because
# the human study ASKED them and our personas simply HAVE them.
#
# ZIPCODE is deliberately not here. It looks like a demographic, but our
# `Screener 2` carries "Please enter the zip code of the city that you are
# located in" — an exact text match to the W-Tabs title — so it is a real
# answer, not a profile field. The match_on_text pass finds it without being
# told, which is why that pass runs before this table is consulted.
ARCHETYPE_TARGETS = {
    "AGE":       "age_band_banner",
    "GENDER":    "gender_clean",
    "ETHNICITY": "race_banner",
    "INCOME":    "income_band_banner",
    "EDU":       "archetype_education_level",
}

# Markers that are not battery items at all.
#
# The W-Tabs put the concept split in the same ** slot they use for items
# (POSTINT tables 47/48), so 'T1 - SHERIDAN' / 'T2 - GOYER' must be routed to
# the `creative` axis of our mart, not treated as a different question. They
# also confirm G/S = Goyer/Sheridan from the source — Appendix A item 1, open
# since the start of the project.
CONCEPT_RE = re.compile(r"^T[12]\s*-\s*(SHERIDAN|GOYER)$", re.I)
# 'Southtown Cume' is a net across the three Southtown franchises, i.e. a
# derived column, not a question.
DERIVED_RE = re.compile(r"\b(cume|net)\b", re.I)

# Class 3. Ours with no W-Tabs table, and why. Recorded so coverage is honest.
KNOWN_ABSENT = {
    "INTRO2":      "acknowledgement formality, nothing to tabulate",
    "RECONFIRM":   "no-op reconfirmation, nothing to tabulate",
    "PARENT1":     "not tabulated in the human study",
    "PARENT2":     "not tabulated in the human study (and QRE-routed, F11)",
    "RECENTFILM1": "not tabulated in the human study",
    "Screener 1":  "EMPLOY in the banner plan; no W-Tabs table",
    "Screener 2":  "COUNTRY in the banner plan; no W-Tabs table",
}

# The W-Tabs split our single HIGHLIGHT meta into two directional tables.
META_ALIASES = {
    "HIGHLIGHT-POSITIVE": "HIGHLIGHT",
    "HIGHLIGHT-NEGTIVE": "HIGHLIGHT",       # sic, the source misspells it
}


def norm(s):
    """
    Fold for comparison only — never for output.

    Handles the real differences between the two sources: 'Animé' vs 'Anime',
    'Stream movies/ TV series' vs 'Stream movies/series', smart quotes, and the
    double spaces in 'Scroll  social media'.
    """
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.replace("’", "'").replace("‘", "'")
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def our_inventory():
    """(meta, question_text, q_type, question_key) for all 91 questions."""
    inv = {}
    for path in sorted(glob.glob(CSV_GLOB)):
        with open(path, encoding="utf-8-sig", newline="") as fh:
            rd = csv.DictReader(fh)
            idxs = sorted(int(m.group(1)) for c in rd.fieldnames
                          if (m := re.match(r"^Q(\d+)_meta$", c)))
            for row in rd:
                for i in idxs:
                    meta = row.get(f"Q{i}_meta")
                    q = row.get(f"Q{i}_question")
                    if not q or not q.strip():
                        continue
                    key = hashlib.md5(f"{meta}||{q}".encode()).hexdigest()
                    inv.setdefault(key, {
                        "our_meta": meta,
                        "question_text": q,
                        "q_type": row.get(f"Q{i}_type"),
                        "question_key": key,
                    })
    return list(inv.values())


def wtab_items():
    """
    (meta, item) pairs the W-Tabs actually tabulate, with where each came from.

    per_item -> the ** marker is the item.
    summary  -> the marker is the metric and the ROW LABELS are the items.
    plain    -> no item; the table is the question.
    """
    tables = list(csv.DictReader(open(TABLES_PATH, encoding="utf-8")))
    by_table = {(t["banner"], int(t["table_no"])): t for t in tables}

    items = defaultdict(set)          # meta -> {item}
    for t in tables:
        if t["layout"] == "per_item" and t["marker"]:
            items[t["meta"]].add(t["marker"])
        elif t["layout"] == "plain":
            items[t["meta"]].add("")

    if os.path.exists(CELLS_PATH):
        for c in csv.DictReader(open(CELLS_PATH, encoding="utf-8")):
            t = by_table.get((c["banner"], int(c["table_no"])))
            if not t or t["layout"] != "summary":
                continue
            if c["is_sigma"] == "True" or c["is_net"] == "True":
                continue
            if c["row_label"]:
                items[t["meta"]].add(c["row_label"])
    else:
        print(f"WARN {CELLS_PATH} missing — run tools/extract_wtabs.py first; "
              f"summary-table items will be absent.", file=sys.stderr)

    return items, tables


def classify_row(wmeta, item, q, method, note=""):
    """
    Build one crosswalk row, routing it to the class that decides how (and
    whether) it can be compared.

    `question`  -> joins to mart_banner_wtab on question_key. Comparable.
    `open_end`  -> our q_type 1. Excluded from the banner mart by design and
                   tabulated in Phase 4, so a W-Tabs table here has no
                   counterpart yet. HIGHLIGHT alone contributes 242 of these:
                   its "items" are individual story sentences, which is verbatim
                   coding, not a banner row.
    `concept`   -> the ** slot holds the creative, not an item. Maps to our
                   `creative` column.
    `derived`   -> a net or cume column, computable but not a question.
    """
    cls, review = "question", "no"
    if item and CONCEPT_RE.match(item):
        cls = "concept"
        note = note or "concept split, maps to mart `creative` not to an item"
    elif item and DERIVED_RE.search(item):
        cls = "derived"
        note = note or "net/cume column — derivable, not a single question"
    elif q["q_type"] == "1":
        cls = "open_end"
        note = note or "our q_type 1 — excluded from the banner mart, Phase 4"
    return {
        "wtab_meta": wmeta, "wtab_item": item, "target_class": cls,
        "our_meta": q["our_meta"], "question_text": q["question_text"],
        "question_key": q["question_key"], "q_type": q["q_type"],
        "archetype_column": "", "match_method": method,
        "needs_review": review, "note": note,
    }


def strip_meta_prefix(title):
    """'POSTINT. Based on the concept...' -> 'Based on the concept...'"""
    return title.split(".", 1)[1].strip() if "." in title else title.strip()


def match(items, inv, tables):
    """Generate crosswalk rows, grading confidence."""
    by_meta = defaultdict(list)
    for q in inv:
        by_meta[q["our_meta"]].append(q)

    # Pass 0 — match on question WORDING, before trusting meta names.
    #
    # The two studies do not always agree on the meta code even when the
    # question is verbatim identical: the W-Tabs call the zip question ZIPCODE,
    # we carry it under `Screener 2`. Matching text first catches those without
    # anyone having to notice and hardcode them.
    by_text = {norm(q["question_text"]): q for q in inv}
    text_match = {}
    for t in tables:
        n = norm(strip_meta_prefix(t["question_title"]))
        if not n:
            continue
        q = by_text.get(n)
        if q is None:
            # W-Tabs titles are sometimes truncated; accept a prefix match if it
            # is unambiguous.
            hits = [v for k, v in by_text.items() if k.startswith(n) or n.startswith(k)]
            q = hits[0] if len(hits) == 1 else None
        if q is not None:
            text_match[t["meta"]] = q

    rows = []
    for wmeta in sorted(items):
        our_meta = META_ALIASES.get(wmeta, wmeta)

        # Text match wins over the meta-name path and over ARCHETYPE_TARGETS.
        if wmeta not in by_meta and wmeta in text_match:
            q = text_match[wmeta]
            for item in sorted(items[wmeta]):
                rows.append(classify_row(wmeta, item, q, "text_exact",
                                         f"W-Tabs meta '{wmeta}' = our '{q['our_meta']}'"))
            continue

        if wmeta in ARCHETYPE_TARGETS:
            rows.append({
                "wtab_meta": wmeta, "wtab_item": "", "target_class": "archetype",
                "our_meta": "", "question_text": "",
                "question_key": "", "q_type": "",
                "archetype_column": ARCHETYPE_TARGETS[wmeta],
                "match_method": "explicit", "needs_review": "no",
                "note": "persona attribute, not a question — validates the banner cut",
            })
            continue

        candidates = by_meta.get(our_meta, [])
        if not candidates:
            rows.append({
                "wtab_meta": wmeta, "wtab_item": "", "target_class": "no_match",
                "our_meta": "", "question_text": "", "question_key": "",
                "q_type": "", "archetype_column": "",
                "match_method": "none", "needs_review": "yes",
                "note": f"no meta '{our_meta}' in our 91 questions",
            })
            continue

        for item in sorted(items[wmeta]):
            # Single-question meta: the table IS the question, no item to resolve.
            if len(candidates) == 1:
                rows.append(classify_row(wmeta, item, candidates[0], "sole_question"))
                continue

            # Battery: the item should appear inside exactly one question_text.
            n_item = norm(item)
            hits = [q for q in candidates if n_item and n_item in norm(q["question_text"])]
            if len(hits) == 1:
                method, review, note = "item_in_text", "no", ""
            elif len(hits) > 1:
                # Prefer the shortest text — 'Anime' matches both 'Anime' and
                # 'Japanese Anime' style wordings; shortest is the bare item.
                hits = [min(hits, key=lambda q: len(q["question_text"]))]
                method, review, note = "item_in_text_ambiguous", "yes", \
                    f"{len(hits)} candidates contained the item; took shortest"
            elif CONCEPT_RE.match(item) or DERIVED_RE.search(item):
                rows.append(classify_row(wmeta, item, candidates[0], "marker_not_item"))
                continue
            else:
                rows.append({
                    "wtab_meta": wmeta, "wtab_item": item,
                    "target_class": "no_match", "our_meta": our_meta,
                    "question_text": "", "question_key": "", "q_type": "",
                    "archetype_column": "", "match_method": "none",
                    "needs_review": "yes",
                    "note": f"item not found in any of {len(candidates)} {our_meta} questions",
                })
                continue

            r = classify_row(wmeta, item, hits[0], method, note)
            if review == "yes":
                r["needs_review"] = "yes"
            rows.append(r)

    # Ours with no W-Tabs counterpart.
    matched_keys = {r["question_key"] for r in rows if r["question_key"]}
    for q in sorted(inv, key=lambda x: (x["our_meta"], x["question_text"])):
        if q["question_key"] in matched_keys:
            continue
        reason = KNOWN_ABSENT.get(q["our_meta"], "no W-Tabs table for this item")
        rows.append({
            "wtab_meta": "", "wtab_item": "", "target_class": "ours_only",
            **{k: q[k] for k in ("our_meta", "question_text", "question_key", "q_type")},
            "archetype_column": "", "match_method": "none",
            "needs_review": "no" if q["our_meta"] in KNOWN_ABSENT else "yes",
            "note": reason,
        })
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="print coverage, write nothing")
    args = ap.parse_args()

    if not os.path.exists(TABLES_PATH):
        sys.exit(f"ERROR: {TABLES_PATH} not found — run tools/extract_wtabs.py first.")

    inv = our_inventory()
    if len(inv) != EXPECTED_QUESTIONS:
        sys.exit(f"ERROR: derived {len(inv)} questions, expected {EXPECTED_QUESTIONS} "
                 f"(Gate 3). The local derivation has drifted from sql/11_stg_response.sql.")
    metas = len({q["our_meta"] for q in inv})
    if metas != EXPECTED_METAS:
        sys.exit(f"ERROR: derived {metas} metas, expected {EXPECTED_METAS}.")
    print(f"Our inventory: {len(inv)} questions, {metas} metas — matches Gate 3.")

    items, tables = wtab_items()
    rows = match(items, inv, tables)

    cls = Counter(r["target_class"] for r in rows)
    rev = sum(1 for r in rows if r["needs_review"] == "yes")
    keys = len({r["question_key"] for r in rows
                if r["target_class"] == "question" and r["question_key"]})
    print(f"\nCrosswalk rows: {len(rows)}")
    for k in ("question", "open_end", "concept", "derived", "archetype",
              "no_match", "ours_only"):
        print(f"  {k:11s} {cls.get(k, 0)}")
    print(f"\nOur questions covered: {keys}/{EXPECTED_QUESTIONS}")
    print(f"Rows needing review  : {rev}")

    if rev:
        print("\n--- needs_review ---")
        for r in rows:
            if r["needs_review"] == "yes":
                print(f"  [{r['target_class']:9s}] {r['wtab_meta'] or r['our_meta']:<20} "
                      f"{(r['wtab_item'] or r['question_text'])[:52]:<52} {r['note'][:44]}")

    if args.report:
        print("\n--report — nothing written.")
        return

    fields = ["wtab_meta", "wtab_item", "target_class", "our_meta", "question_text",
              "question_key", "q_type", "archetype_column", "match_method",
              "needs_review", "note"]
    os.makedirs("ref", exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    print(f"\nWrote {OUT_PATH}")


if __name__ == "__main__":
    main()
