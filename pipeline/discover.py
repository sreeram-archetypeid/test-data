"""
Stage 1-2: Structure discovery -> draft manifest.

Study-agnostic. Nothing here knows about any particular survey: the repeating
block size, slot names, attribute-column count and respondent ID column are all
inferred from the files themselves.

Maps to: Cloud Run job "discovery" in the cloud build.
"""
import csv, json, re, sys, hashlib, statistics
from collections import defaultdict, Counter
from pathlib import Path

csv.field_size_limit(10 ** 9)

# ---------------------------------------------------------------- grammars
# A grammar turns a column name into (stem, index, slot) or None.
# Adding a grammar is config, not code -- these live in grammars.json later.
GRAMMARS = [
    ("G1_stem_idx_us_slot", r"^(?P<stem>[A-Za-z]+)(?P<idx>\d+)_(?P<slot>.+)$"),
    ("G2_slot_us_stem_idx", r"^(?P<slot>.+)_(?P<stem>[A-Za-z]+)(?P<idx>\d+)$"),
    ("G3_stem_idx_dot_slot", r"^(?P<stem>[A-Za-z]+)(?P<idx>\d+)\.(?P<slot>.+)$"),
    ("G4_stem_us_idx_us_slot", r"^(?P<stem>[A-Za-z]+)_(?P<idx>\d+)_(?P<slot>.+)$"),
    ("G6_flat", r"^(?P<stem>[A-Za-z]+)(?P<idx>\d+)$"),
]


def read_csv(path):
    """RFC-4180 safe read. Never line-based: physical lines != records."""
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rdr = csv.reader(fh)
        header = next(rdr)
        rows = [r for r in rdr]
    ragged = [i for i, r in enumerate(rows) if len(r) != len(header)]
    return header, rows, ragged


def apply_grammar(pattern, header):
    """Parse every column under one grammar. Returns parsed map + leftovers."""
    rx = re.compile(pattern)
    parsed, unparsed = {}, []
    for i, name in enumerate(header):
        m = rx.match(name.strip())
        if m:
            g = m.groupdict()
            parsed[i] = (g["stem"], int(g["idx"]), g.get("slot", "_value"))
        else:
            unparsed.append(i)
    return parsed, unparsed


def score_grammar(parsed, unparsed, n_cols):
    """
    Score how well a grammar explains the header.
    Deliberately conservative -- a low score must refuse, not guess.
    """
    if not parsed:
        return 0.0, {}
    groups = defaultdict(list)
    for ordinal, (stem, idx, slot) in parsed.items():
        groups[(stem, idx)].append((ordinal, slot))

    slot_sets = [tuple(sorted(s for _, s in v)) for v in groups.values()]
    modal = Counter(slot_sets).most_common(1)[0][0]
    uniformity = sum(1 for s in slot_sets if s == modal) / len(slot_sets)

    idxs = sorted({idx for _, idx in groups})
    density = len(idxs) / (max(idxs) - min(idxs) + 1) if idxs else 0

    contiguous = 0
    for v in groups.values():
        ords = sorted(o for o, _ in v)
        if ords == list(range(ords[0], ords[0] + len(ords))):
            contiguous += 1
    contiguity = contiguous / len(groups)

    # leftovers should form a clean prefix block
    prefix_purity = 0.0
    if unparsed:
        run = 0
        for i in range(len(unparsed)):
            if unparsed[i] == i:
                run += 1
            else:
                break
        prefix_purity = run / len(unparsed)

    coverage = len(parsed) / n_cols
    score = (0.35 * coverage + 0.25 * uniformity + 0.20 * contiguity
             + 0.10 * density + 0.10 * prefix_purity)
    return score, {
        "coverage": round(coverage, 4), "uniformity": round(uniformity, 4),
        "contiguity": round(contiguity, 4), "density": round(density, 4),
        "prefix_purity": round(prefix_purity, 4),
        "block_size": len(modal), "block_count": len(idxs),
        "slots": list(modal),
    }


def detect_id_column(header, rows, attr_ordinals, cross_file_values):
    """
    Score attribute columns for respondent-ID-ness.
    Refuses if two candidates are within 15% of each other.
    """
    cands = []
    for i in attr_ordinals:
        vals = [r[i] for r in rows if i < len(r)]
        if not vals:
            continue
        nonblank = [v for v in vals if v.strip()]
        if len(nonblank) != len(vals):
            continue                                   # any blank disqualifies
        distinct = len(set(vals))
        distinct_ratio = distinct / len(vals)
        if distinct_ratio < 1.0:
            continue                                   # must be unique in file
        s = 0.5
        name = header[i].lower()
        if re.search(r"(^|_)(id|uuid|respondent|resp|panelist|case|record)($|_)", name):
            s += 0.2
        sample = vals[0]
        if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", sample):
            s += 0.2
        elif sample.isdigit():
            s += 0.05
        # cross-file overlap: a real panel ID recurs across sibling files
        overlap = cross_file_values.get(i, 0)
        if overlap > 0:
            s += 0.15
        if i <= 3:
            s += 0.05
        cands.append((min(s, 1.0), i, header[i]))

    cands.sort(reverse=True)
    if not cands:
        return None, 0.0, None, "no column is unique and fully populated"
    if len(cands) > 1 and cands[0][0] - cands[1][0] < 0.15 * cands[0][0]:
        return (cands[0][2], cands[0][0], cands[1][2],
                "two candidates within the ambiguity margin")
    return cands[0][2], cands[0][0], (cands[1][2] if len(cands) > 1 else None), None


def infer_slot_roles(header, rows, parsed, slots):
    """
    Decide what each slot HOLDS by looking at its data, never its name.
    This is what correctly marks an always-empty slot as UNUSED.
    """
    by_slot = defaultdict(list)
    for ordinal, (stem, idx, slot) in parsed.items():
        by_slot[slot].append(ordinal)

    roles = {}
    sample_rows = rows[: min(len(rows), 400)]
    for slot in slots:
        ords = by_slot.get(slot, [])
        if not ords:
            continue
        vals, per_col_distinct = [], []
        for o in ords:
            col = [r[o] for r in sample_rows if o < len(r)]
            vals.extend(col)
            # distinct among NON-EMPTY values only; an empty column tells us
            # nothing about whether this slot is constant per question.
            per_col_distinct.append(len({v.strip() for v in col if v.strip()}))
        nonblank = [v for v in vals if v.strip()]
        fill = len(nonblank) / max(len(vals), 1)
        if fill == 0:
            roles[slot] = ("UNUSED", fill, 0)
            continue
        avg_len = statistics.mean(len(v) for v in nonblank)

        # Constant-within-column means "describes the question, not the answer".
        # Measured only over columns that actually carry data, otherwise a
        # mostly-empty answer slot looks constant and is misread as metadata.
        populated = [d for d in per_col_distinct if d > 0]
        constant_ratio = (sum(1 for d in populated if d == 1) / len(populated)
                          if populated else 0.0)

        distinct_overall = len({v.strip() for v in nonblank})
        numericish = sum(1 for v in nonblank
                         if v.strip().replace(".", "", 1).isdigit())
        numeric_ratio = numericish / len(nonblank)

        if constant_ratio > 0.8 and avg_len > 30:
            role = "QUESTION_TEXT"
        elif constant_ratio > 0.8 and numeric_ratio > 0.9 and avg_len <= 3:
            # a tiny numeric vocabulary shared across blocks is a type code;
            # an alphanumeric label of the same shape is a question code
            role = "QUESTION_TYPE"
        elif constant_ratio > 0.8:
            role = "QUESTION_CODE"
        elif numeric_ratio > 0.9 and avg_len <= 4:
            role = "NUMERIC_RESPONSE"
        elif distinct_overall / max(len(nonblank), 1) > 0.5 and avg_len > 40:
            role = "OPEN_RESPONSE"
        else:
            role = "CLOSED_RESPONSE"
        roles[slot] = (role, round(fill, 4), distinct_overall)
    return roles


def discover(drop_dir):
    drop = Path(drop_dir)
    files = sorted(p for p in drop.glob("*.csv"))
    if not files:
        raise SystemExit(f"no .csv files in {drop}")

    per_file, all_ids = [], defaultdict(set)
    for p in files:
        header, rows, ragged = read_csv(p)
        best, best_score, best_detail = None, 0.0, None
        runner = 0.0
        for gid, pat in GRAMMARS:
            parsed, unparsed = apply_grammar(pat, header)
            sc, detail = score_grammar(parsed, unparsed, len(header))
            if sc > best_score:
                runner, best_score = best_score, sc
                best, best_detail = (gid, parsed, unparsed), detail
            elif sc > runner:
                runner = sc
        gid, parsed, unparsed = best
        per_file.append({
            "path": str(p), "name": p.name, "header": header, "rows": rows,
            "ragged": ragged, "grammar": gid, "parsed": parsed,
            "attr_ordinals": unparsed, "score": round(best_score, 4),
            "runner_up": round(runner, 4), "detail": best_detail,
        })

    # cross-file value overlap, for ID detection
    for f in per_file:
        for i in f["attr_ordinals"][:6]:
            all_ids[i] |= {r[i] for r in f["rows"][:50] if i < len(r)}

    f0 = per_file[0]
    overlap = {}
    for i in f0["attr_ordinals"][:6]:
        seen = 0
        for f in per_file[1:]:
            if i in f["attr_ordinals"]:
                vals = {r[i] for r in f["rows"][:50] if i < len(r)}
                if vals & all_ids[i]:
                    seen += 1
        overlap[i] = seen

    id_col, id_conf, runner_up, id_problem = detect_id_column(
        f0["header"], f0["rows"], f0["attr_ordinals"], overlap)

    roles = infer_slot_roles(f0["header"], f0["rows"], f0["parsed"],
                             f0["detail"]["slots"])

    grammars = {f["grammar"] for f in per_file}
    refusals = []
    if len(grammars) > 1:
        refusals.append(f"sibling files disagree on naming grammar: {grammars}")
    if id_problem:
        refusals.append(f"respondent id: {id_problem}")
    for f in per_file:
        if f["ragged"]:
            refusals.append(f"{f['name']}: {len(f['ragged'])} ragged rows")
        if f["score"] < 0.80:
            refusals.append(f"{f['name']}: structure confidence {f['score']} below 0.80")
        if f["score"] - f["runner_up"] < 0.05:
            refusals.append(f"{f['name']}: two grammars within 0.05 -- ambiguous")

    manifest = {
        "manifest_version": "1.0.0",
        "status": "REFUSED" if refusals else "DRAFT",
        "drop_id": drop.name,
        "refusals": refusals,
        "structure": {
            "grammar_id": f0["grammar"],
            "confidence": f0["score"],
            "runner_up_score": f0["runner_up"],
            "id_column": {"name": id_col, "confidence": round(id_conf, 3),
                          "runner_up": runner_up},
            "attribute_column_count": len(f0["attr_ordinals"]),
            "attribute_columns": [f0["header"][i] for i in f0["attr_ordinals"]],
            "slots": [{"name": s, "role": roles.get(s, ("?", 0, 0))[0],
                       "fill_rate": roles.get(s, ("?", 0, 0))[1],
                       "distinct": roles.get(s, ("?", 0, 0))[2]}
                      for s in f0["detail"]["slots"]],
            "metrics": {k: f0["detail"][k] for k in
                        ("coverage", "uniformity", "contiguity", "density",
                         "prefix_purity")},
        },
        "files": [{"name": f["name"], "columns": len(f["header"]),
                   "records": len(f["rows"]),
                   "block_count": f["detail"]["block_count"],
                   "block_size": f["detail"]["block_size"],
                   "expected_long_rows": len(f["rows"]) * f["detail"]["block_count"]}
                  for f in per_file],
        "expected_long_rows_total": sum(
            len(f["rows"]) * f["detail"]["block_count"] for f in per_file),
        # ---- fields a human must confirm (Gate 1). null = unanswered.
        "requires_human": {
            "scale_direction": None,         # "1_IS_BEST" | "1_IS_WORST"
            "sentinel_codes": None,          # e.g. [98, 99]
            "dedup_policy": None,            # "KEEP_ALL" | "PRIMARY_ONLY"
            "banner_cuts": None,
        },
    }
    return manifest


if __name__ == "__main__":
    out = discover(sys.argv[1])
    Path(sys.argv[2]).write_text(json.dumps(out, indent=2))
    print(json.dumps({k: out[k] for k in
                      ("status", "refusals", "expected_long_rows_total")}, indent=2))
    print(json.dumps(out["structure"], indent=2)[:2000])
