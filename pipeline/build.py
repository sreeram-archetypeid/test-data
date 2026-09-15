"""
Stages 3-6: unpivot -> clean -> curated -> tidy banner.

Everything here is driven by the discovered manifest plus the Gate 1 answers.
No question codes, cut names, scale assumptions or respondent counts are
hardcoded; point it at a different survey and it follows that survey's manifest.

Maps to: the Dataform models (ops_unpivot, stg_response, dim_*, fct_*,
mart_banner) in the cloud build. Kept in Python here so the logic can be
proven before it is ported to SQL.
"""
import csv, json, re, sys, statistics
from collections import defaultdict, Counter
from pathlib import Path

csv.field_size_limit(10 ** 9)

# Strips a leading option code, tolerating the doubled form "1. 1. Label"
CODE_RX = re.compile(r"^\s*(\d+)\.\s*(?:\1\.\s*)?(.*)$")


def load_rows(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rdr = csv.reader(fh)
        header = next(rdr)
        return header, [r for r in rdr]


def parse_option(raw):
    """'1. 1. Probably interested' -> (1, 'Probably interested')"""
    m = CODE_RX.match(raw)
    if m:
        return int(m.group(1)), m.group(2).strip()
    return None, raw.strip()


def unpivot(drop_dir, manifest):
    """
    Wide -> long. One record per respondent per question block.
    Block size, slot names and slot roles all come from the manifest.
    """
    struct = manifest["structure"]
    slot_names = [s["name"] for s in struct["slots"]]
    roles = {s["name"]: s["role"] for s in struct["slots"]}
    id_col = struct["id_column"]["name"]
    attr_cols = struct["attribute_columns"]
    grammar = re.compile(r"^(?P<stem>[A-Za-z]+)(?P<idx>\d+)_(?P<slot>.+)$")

    long_rows, respondents = [], {}
    for f in manifest["files"]:
        path = Path(drop_dir) / f["name"]
        header, rows = load_rows(path)
        idx_of = {name: i for i, name in enumerate(header)}

        # map (block_index, slot) -> column ordinal, from the header alone
        blocks = defaultdict(dict)
        for i, name in enumerate(header):
            m = grammar.match(name.strip())
            if m:
                blocks[int(m.group("idx"))][m.group("slot")] = i

        for row in rows:
            rid = row[idx_of[id_col]]
            key = (rid, f["name"])
            respondents[key] = {
                "respondent_id": rid,
                "source_file": f["name"],
                **{c: row[idx_of[c]] for c in attr_cols if c in idx_of},
            }
            for bidx, slots in sorted(blocks.items()):
                rec = {"respondent_id": rid, "source_file": f["name"],
                       "block_index": bidx}
                for slot, ordinal in slots.items():
                    rec[slot] = row[ordinal] if ordinal < len(row) else ""
                long_rows.append(rec)
    return long_rows, respondents, roles, slot_names


def clean(long_rows, roles, gate1):
    """
    Parse the raw slot values into typed fields using the inferred roles.
    Multi-select splitting, option-code stripping, verbatim capture.
    """
    text_slot = next((s for s, r in roles.items() if r == "QUESTION_TEXT"), None)
    code_slot = next((s for s, r in roles.items() if r == "QUESTION_CODE"), None)
    type_slot = next((s for s, r in roles.items() if r == "QUESTION_TYPE"), None)
    closed_slot = next((s for s, r in roles.items() if r == "CLOSED_RESPONSE"), None)
    open_slot = next((s for s, r in roles.items() if r == "OPEN_RESPONSE"), None)
    num_slot = next((s for s, r in roles.items() if r == "NUMERIC_RESPONSE"), None)

    delim = gate1.get("multiselect_delimiter", "|")
    out = []
    for r in long_rows:
        qtext = (r.get(text_slot) or "").strip()
        if not qtext:
            continue                        # unused block slot in a short file
        selections = []
        raw_sel = (r.get(closed_slot) or "").strip()
        if raw_sel:
            for tok in raw_sel.split(delim):
                if tok.strip():
                    code, label = parse_option(tok)
                    selections.append({"code": code, "label": label})
        num = (r.get(num_slot) or "").strip()
        out.append({
            "respondent_id": r["respondent_id"],
            "source_file": r["source_file"],
            "block_index": r["block_index"],
            "question_text": qtext,
            "question_code": (r.get(code_slot) or "").strip(),
            "question_type": (r.get(type_slot) or "").strip(),
            "selections": selections,
            "verbatim": (r.get(open_slot) or "").strip() or None,
            "numeric": int(num) if num.isdigit() else None,
        })
    return out


def build_questions(clean_rows, gate1):
    """
    One row per distinct question identity, with scale_max derived from the
    observed option universe minus sentinels. Keyed on (code, text) because a
    code alone can cover several distinct questions.
    """
    sentinel_min = gate1.get("sentinel_min_code", 90)
    max_scale_points = gate1.get("max_scale_points", 10)
    opts = defaultdict(set)
    kinds, max_picks, has_numeric, has_verbatim = {}, defaultdict(int), \
        defaultdict(bool), defaultdict(bool)
    numeric_max = defaultdict(int)

    for r in clean_rows:
        key = (r["question_code"], r["question_text"])
        kinds[key] = r["question_type"]
        picks = 0
        for s in r["selections"]:
            if s["code"] is not None:
                opts[key].add((s["code"], s["label"]))
                picks += 1
        max_picks[key] = max(max_picks[key], picks)
        if r["numeric"] is not None:
            has_numeric[key] = True
            numeric_max[key] = max(numeric_max[key], r["numeric"])
        if r["verbatim"]:
            has_verbatim[key] = True

    questions = {}
    for key in set(list(opts) + list(kinds)):
        universe = opts.get(key, set())
        real = [c for c, _ in universe if c < sentinel_min]
        scale_max = max(real) if real else None

        # Classify how this question should be tabulated. Box metrics are only
        # meaningful on an ordered scale where each respondent picks one point.
        # A 20-option pick-list has no "bottom box", and a multi-select has no
        # single answer to take a box of.
        if universe and max_picks[key] <= 1 and scale_max \
                and 2 <= scale_max <= max_scale_points:
            kind = "SCALE"
        elif universe:
            kind = "SELECT"
        elif has_numeric[key]:
            kind = "NUMERIC"
        elif has_verbatim[key]:
            kind = "OPEN"
        else:
            kind = "EMPTY"

        questions[key] = {
            "question_code": key[0], "question_text": key[1],
            "question_type": kinds.get(key),
            "tabulation": kind,
            "scale_max": scale_max if kind == "SCALE"
                         else (numeric_max[key] if kind == "NUMERIC" else scale_max),
            "max_selections": max_picks[key],
            "n_options": len(universe),
            "options": sorted(universe),
            "sentinels": sorted(c for c, _ in universe if c >= sentinel_min),
        }
    return questions


def mark_primary(clean_rows, gate1):
    """
    A respondent can answer the same question in more than one file. Rank the
    duplicates deterministically and flag one as primary, so metrics can be
    computed on a clean base without discarding the replicate.
    """
    groups = defaultdict(list)
    for i, r in enumerate(clean_rows):
        groups[(r["respondent_id"], r["question_code"], r["question_text"])].append(i)
    for key, idxs in groups.items():
        ordered = sorted(idxs, key=lambda i: clean_rows[i]["source_file"])
        for rank, i in enumerate(ordered):
            clean_rows[i]["is_primary"] = (rank == 0)
            clean_rows[i]["n_runs"] = len(idxs)
    return clean_rows


def primary_code(selections, sentinel_min):
    """Best (lowest) non-sentinel option code a respondent selected."""
    codes = [s["code"] for s in selections
             if s["code"] is not None and s["code"] < sentinel_min]
    return min(codes) if codes else None
