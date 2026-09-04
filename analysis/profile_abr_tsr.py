#!/usr/bin/env python3
"""
Profiler for the ABR-TSR (Air Bud Returns) synthetic kids trailer test.

Reproduces every measured number in AIR_BUD_RETURNS_DATA_ASSESSMENT.md.

Usage:
    python3 analysis/profile_abr_tsr.py T1.csv T23.csv

Inputs are the two wide exports:
    ABR-TSR_RETURN_v4_K_T1  — Results.csv   (ages 4-7,  groups K1-K4)
    ABR-TSR_RETURN_v4_K_T23 — Results.csv   (ages 8-12, groups K5-K9)
"""
import re
import sys
from collections import Counter

import pandas as pd

STAGE_DIR = re.compile(r"\[[^\]]*\]")
ASTERISK_ACTION = re.compile(r"\*[^*]*\*")
FATIGUE = re.compile(
    r"tired|are we done|can i go|my hands hurt|brain is tired|stop asking|"
    r"no more question|i don'?t want to type|bored of this|enough question|"
    r"wanna go play|hands are tired",
    re.I,
)
LEAKED_JSON = re.compile(r'^\s*\{\s*"targetLanguage"|"mixtureOfExperts"')


def load(path):
    return pd.read_csv(path, dtype=str, keep_default_na=False)


def question_ids(df):
    return sorted({int(m.group(1)) for c in df.columns
                   if (m := re.match(r"Q(\d+)_", c))})


def strip_performance(text):
    """Remove roleplay stage directions before any semantic analysis."""
    text = STAGE_DIR.sub(" ", text)
    text = ASTERISK_ACTION.sub(" ", text)
    return re.sub(r"\s+", " ", text).strip()


def profile_structure(name, df):
    qids = question_ids(df)
    closed = [q for q in qids if df[f"Q{q}_type"].iloc[0] in ("4", "5")]
    open_q = [q for q in qids if df[f"Q{q}_type"].iloc[0] == "1"]
    print(f"\n=== {name} ===")
    print(f"  rows={len(df)}  cols={len(df.columns)}  questions={len(qids)}"
          f"  (closed={len(closed)}, open={len(open_q)})")
    print(f"  unique personas={df.archetype_id.nunique()}"
          f"  groups={sorted(df.group_name.unique())}")
    print(f"  ages={sorted(df.archetype_age_range.unique(), key=int)}")

    # The rating channel is unpopulated in this export -- all quant is text.
    r = sum((df[f"Q{q}_rating"].str.strip() != "").sum() for q in qids)
    rl = sum((df[f"Q{q}_rating_label"].str.strip() != "").sum() for q in qids)
    print(f"  populated 'rating' cells={r}   'rating_label' cells={rl}"
          f"   -> {'EMPTY: no numeric codes exist' if r == rl == 0 else 'present'}")
    return closed, open_q


def profile_missingness(name, df, closed):
    miss = pd.DataFrame({f"Q{q}": df[f"Q{q}_selected"].str.strip() == ""
                         for q in closed})
    per = miss.sum(axis=1)
    print(f"\n  [{name}] closed-end blanks={int(miss.values.sum())}"
          f" ({miss.values.mean() * 100:.1f}%)"
          f"  personas affected={(per > 0).sum()}/{len(df)}")
    for i, v in per[per > 0].sort_values(ascending=False).items():
        print(f"      {df.at[i, 'archetype_name']:14s}"
              f" ({df.at[i, 'group_name']}, age {df.at[i, 'archetype_age_range']})"
              f" blanks={v}")


def profile_qual(name, df, open_q):
    print(f"\n  [{name}] open-end diagnostics")
    for q in open_q:
        v = df[f"Q{q}_qual"].str.strip()
        v = v[v != ""]
        if v.empty:
            continue
        n = len(v)
        stage = v.str.contains(STAGE_DIR).sum()
        fat = sum(bool(FATIGUE.search(s)) for s in v)
        leak = sum(bool(LEAKED_JSON.search(s)) for s in v)
        lens = v.str.len()
        print(f"    Q{q:<3d} n={n:3d} avg_len={lens.mean():5.0f}"
              f" max={lens.max():5d} stage_dir={stage / n * 100:3.0f}%"
              f" fatigue={fat / n * 100:3.0f}%"
              f" leaked_json={leak}"
              f" exact_dupes={n - v.nunique()}")


def profile_scales(pairs, a, b):
    print("\n=== SCALE GRANULARITY MISMATCH ===")
    for label, qa, qb in pairs:
        na = a[f"Q{qa}_selected"].replace("", pd.NA).dropna().nunique()
        nb = b[f"Q{qb}_selected"].replace("", pd.NA).dropna().nunique()
        flag = "  <== MISMATCH" if na != nb else ""
        print(f"  {label:22s} T1={na}pt  T23={nb}pt{flag}")


def reconcile(tests):
    """T1 top-box vs T23 top-2-box -- the only defensible cross-file compare."""
    print("\n=== SCALE-COLLAPSE RECONCILIATION ===")
    print(f"  {'construct':22s} {'T1 TB':>7s} {'T23 T2B':>9s} {'gap':>6s}")
    for label, da, qa, ta, db, qb, tb in tests:
        va = da[f"Q{qa}_selected"].replace("", pd.NA).dropna()
        vb = db[f"Q{qb}_selected"].replace("", pd.NA).dropna()
        pa, pb = va.isin(ta).mean() * 100, vb.isin(tb).mean() * 100
        print(f"  {label:22s} {pa:6.0f}% {pb:8.0f}% {pb - pa:+5.0f}")


def coherence(name, df):
    """Closed-end vs open-end contradiction rate -- the validation lever."""
    loud = r"\bloud\b|yell|shout|noise|buzzer|scream"
    txt = (df["Q32_qual"].map(strip_performance) + " "
           + df["Q28_qual"].map(strip_performance))
    not_scary = df["Q25_selected"].str.strip() == "Not at all"
    complained = txt.str.contains(loud, case=False)
    n = len(df)
    print(f"\n  [{name}] scored 'not scary'={not_scary.sum()}"
          f"  volunteered sensory complaint={complained.sum()}"
          f"  CONTRADICTION={(not_scary & complained).sum()}"
          f" ({(not_scary & complained).mean() * 100:.0f}% of n={n})")


def multiselect(name, df, q):
    c = Counter()
    v = df[f"Q{q}_selected"].replace("", pd.NA).dropna()
    for s in v:
        c.update(x.strip() for x in s.split("|") if x.strip())
    print(f"\n  [{name}] Q{q} (base={len(v)})")
    for k, n in c.most_common():
        print(f"      {k:42s} {n:4d} ({n / len(v) * 100:5.1f}%)")
    over = (v.str.count(r"\|") + 1 > 3).sum()
    print(f"      >3 picks (rule violations): {over}")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    a, b = load(sys.argv[1]), load(sys.argv[2])

    closed_a, open_a = profile_structure("T1 (ages 4-7)", a)
    closed_b, open_b = profile_structure("T23 (ages 8-12)", b)

    print(f"\n  persona overlap between files:"
          f" ids={len(set(a.archetype_id) & set(b.archetype_id))}"
          f" names={len(set(a.archetype_name) & set(b.archetype_name))}"
          f" groups={len(set(a.group_name) & set(b.group_name))}")

    profile_missingness("T1", a, closed_a)
    profile_missingness("T23", b, closed_b)
    profile_qual("T1", a, open_a)
    profile_qual("T23", b, open_b)

    profile_scales(
        [("Liked trailer", 7, 8), ("Want to see", 9, 10), ("Funny", 11, 12),
         ("Exciting", 13, 14), ("Root for char", 15, 16),
         ("Bball->next", 17, 18), ("Understand", 19, 20),
         ("Kids+grownups", 21, 22), ("Ask parent", 38, 39),
         ("Watch home", 42, 41), ("Tell friend", 48, 48),
         ("Title like", 51, 52), ("Bball affinity", 55, 54)],
        a, b)

    reconcile([
        ("Liked trailer", a, 7, ["I liked it a lot"],
         b, 8, ["I liked it a lot!", "I liked it!"]),
        ("Want to see", a, 9, ["Yes!"],
         b, 10, ["I really want to see it", "I want to see it"]),
        ("Exciting", a, 13, ["Very exciting"],
         b, 14, ["Super exciting", "Very exciting"]),
        ("Kids+grownups", a, 21, ["Yes"],
         b, 22, ["Definitely yes", "Probably yes"]),
        ("Ask parent->theatre", a, 38, ["Yes"],
         b, 39, ["Definitely yes", "Probably yes"]),
        ("Tell a friend", a, 48, ["Definitely yes"],
         b, 48, ["Definitely yes", "Probably yes"]),
        ("Title liking", a, 51, ["A lot"],
         b, 52, ["I like it a lot", "I like it"]),
    ])

    print("\n=== CLOSED/OPEN COHERENCE ===")
    coherence("T1", a)
    coherence("T23", b)

    print("\n=== CONTENT: liked elements / emotions ===")
    for nm, df in (("T1", a), ("T23", b)):
        multiselect(nm, df, 33)
        multiselect(nm, df, 35)

    print("\n=== BANNER BASE SIZES (pooled) ===")
    both = pd.concat([a, b], ignore_index=True, sort=False)
    for col in ("group_name", "archetype_age_range", "archetype_gender",
                "archetype_race"):
        print(f"\n  {col}:")
        for k, v in both[col].value_counts().items():
            tag = ("OK" if v >= 100 else
                   "CAUTION" if v >= 30 else "LOW BASE - DO NOT REPORT")
            print(f"      {str(k):44s} n={v:4d}  {tag}")


if __name__ == "__main__":
    main()
