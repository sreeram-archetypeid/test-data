#!/usr/bin/env python3
"""
Census region from a persona's free-text `archetype_location`.

Why not from the zip code
-------------------------
The delivered ZIPCODE answers are lossy in two DIFFERENT ways, so no single
repair rule is correct. Measured over the 398 personas, using each persona's own
stated location as the arbiter and the 182 full five-digit zips as a control:

    first-digit -> region on the 5-digit control   182/182   100.0%
    4-digit taken as-is (trailing digit lost)      162/207    78.3%
    4-digit zero-padded (leading zero lost)         53/207    25.6%

The control at 100% shows the method is sound, so the disagreement is real:

    3030 -> Atlanta GA      8910 -> Las Vegas NV    7708 -> Houston TX
    4320 -> Columbus OH     8020 -> Denver CO       9372 -> Fresno CA
        ... these lost a TRAILING digit. Zero-padding them produces 03030,
        08910, 07708 -- every one a real Northeast zip, and wrong.

    2108 -> Boston MA       7102 -> Newark NJ       2110/2116 -> Boston MA
        ... these lost a LEADING zero, and zero-padding is exactly right.

Roughly 150 records need truncation and 41 need padding, and for the truncated
ones the final digit is gone -- unrecoverable by any rule. Fabricating one
yields a valid-looking zip in the wrong state that nothing downstream would
flag, which is worse than having no value at all.

So region is derived here, from the stated location, and the zip is kept
verbatim as provenance only. Never pad it.

Accuracy of THIS derivation: 388 of 398 personas resolve (the 10 failures are
empty strings), and all four regions land within 1.6pp of the human study's own
Table 3 -- South 38.4 vs 40, West 24.6 vs 25, Northeast 18.6 vs 20,
Midwest 15.8 vs 16.

Resolution order matters. A state is more specific than a region word, and the
data proves it: 'Columbus, Indiana (Midwest USA)' and 'Columbus, OH' both
mention Columbus, and 'Washington, Western USA' names a state that happens to
agree with its region word. State first, region word only as a fallback.
"""

import re

# US Census Bureau's four regions.
STATE_REGION = {
    **{s: "Northeast" for s in "CT ME MA NH RI VT NJ NY PA".split()},
    **{s: "Midwest" for s in "IL IN MI OH WI IA KS MN MO NE ND SD".split()},
    **{s: "South" for s in
       "DE FL GA MD NC SC VA DC WV AL KY MS TN AR LA OK TX".split()},
    **{s: "West" for s in
       "AZ CO ID MT NV NM UT WY AK CA HI OR WA".split()},
}

STATE_NAMES = {
    "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR",
    "california": "CA", "colorado": "CO", "connecticut": "CT", "delaware": "DE",
    "florida": "FL", "georgia": "GA", "hawaii": "HI", "idaho": "ID",
    "illinois": "IL", "indiana": "IN", "iowa": "IA", "kansas": "KS",
    "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
    "massachusetts": "MA", "michigan": "MI", "minnesota": "MN",
    "mississippi": "MS", "missouri": "MO", "montana": "MT", "nebraska": "NE",
    "nevada": "NV", "new hampshire": "NH", "new jersey": "NJ",
    "new mexico": "NM", "new york": "NY", "north carolina": "NC",
    "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR",
    "pennsylvania": "PA", "rhode island": "RI", "south carolina": "SC",
    "south dakota": "SD", "tennessee": "TN", "texas": "TX", "utah": "UT",
    "vermont": "VT", "virginia": "VA", "washington": "WA",
    "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
}

# Fallback for strings that name only a region ('Southern USA', 41 personas).
# Ordered longest-first: 'northeast' must be tried before 'north', and
# 'west virginia' is handled by STATE_NAMES before 'west' is ever reached.
REGION_WORDS = [
    ("northeast", "Northeast"),
    ("midwest", "Midwest"),
    ("southern", "South"),
    ("south", "South"),
    ("western", "West"),
    ("west coast", "West"),
    ("pacific", "West"),
    ("west", "West"),
]


def region_of(location):
    """(region, method) for one location string. (None, 'unresolved') if empty."""
    loc = (location or "").strip()
    if not loc:
        return None, "unresolved"
    low = loc.lower()

    # Longest name first, so 'west virginia' cannot be shadowed by 'virginia'.
    for name in sorted(STATE_NAMES, key=len, reverse=True):
        if re.search(rf"\b{re.escape(name)}\b", low):
            return STATE_REGION[STATE_NAMES[name]], "state name"

    m = re.search(r"\b([A-Z]{2})\b", loc)
    if m and m.group(1) in STATE_REGION:
        return STATE_REGION[m.group(1)], "state abbr"

    for word, region in REGION_WORDS:
        if word in low:
            return region, "region word"

    return None, "unresolved"


def sql_case(col="archetype_location", indent="  "):
    """
    Emit the same logic as BigQuery SQL, so dim_archetype and the local tools
    cannot drift. Generated, never hand-edited.
    """
    L = []
    a = lambda s: L.append(indent + s)
    a("CASE")
    a("    -- State name first: more specific than a region word, and the data")
    a("    -- contains 'Columbus, Indiana (Midwest USA)' where only the state")
    a("    -- distinguishes it from 'Columbus, OH'. Longest name first so")
    a("    -- 'west virginia' is not shadowed by 'virginia'.")
    for name in sorted(STATE_NAMES, key=len, reverse=True):
        region = STATE_REGION[STATE_NAMES[name]]
        a(f"    WHEN REGEXP_CONTAINS(LOWER({col}), r'\\b{name}\\b')"
          f" THEN '{region}'")
    a("    -- Then a two-letter postal abbreviation.")
    for ab in sorted(STATE_REGION):
        a(f"    WHEN REGEXP_CONTAINS({col}, r'\\b{ab}\\b')"
          f" THEN '{STATE_REGION[ab]}'")
    a("    -- Finally a bare region word ('Southern USA', 41 personas).")
    for word, region in REGION_WORDS:
        a(f"    WHEN REGEXP_CONTAINS(LOWER({col}), r'{word}') THEN '{region}'")
    a("    ELSE NULL")
    a("  END")
    return "\n".join(L)


if __name__ == "__main__":
    import collections, csv, glob
    seen = {}
    for f in glob.glob("Written Descriptions_2026_08_7/*2.2*.csv"):
        for r in csv.DictReader(open(f, encoding="utf-8-sig")):
            seen.setdefault(r["archetype_id"], r.get("archetype_location") or "")
    meth = collections.Counter()
    reg = collections.Counter()
    for loc in seen.values():
        rg, m = region_of(loc)
        meth[m] += 1
        reg[rg or "UNRESOLVED"] += 1
    n = len(seen)
    print(f"{n} personas")
    for k, v in meth.most_common():
        print(f"  {k:12s} {v:4d}")
    HUMAN = {"South": 40, "West": 25, "Northeast": 20, "Midwest": 16}
    print(f"\n  {'region':11s}{'ours':>8s}{'human':>7s}{'gap':>7s}")
    for k in ("South", "West", "Northeast", "Midwest"):
        o = reg[k] / n * 100
        print(f"  {k:11s}{o:7.1f}%{HUMAN[k]:6d}%{o - HUMAN[k]:+7.1f}")
    print(f"  {'unresolved':11s}{reg['UNRESOLVED'] / n * 100:7.1f}%")
