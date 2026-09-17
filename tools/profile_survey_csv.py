#!/usr/bin/env python3
"""Profile wide survey CSV exports and emit a load manifest.

The exports this pipeline consumes are "wide": a block of entity attribute
columns followed by N repeating per-question blocks::

    archetype_id, group_name, ... , Q1_question, Q1_meta, ... , Q36_qual

Nothing downstream should hardcode 46 attributes, 7 facets, 20/35/36 questions
or 40,178 fact rows. Those are properties of one export, not of the format.
This profiler measures them per file and writes them to a manifest, which is
what the BigQuery load, the dynamic UNPIVOT and the DQ assertions read.

Usage::

    python3 tools/profile_survey_csv.py "Written Descriptions_2026_08_7"/*.csv \
        --modality READ --out build/manifest.json --schema-dir build/schemas

Outputs:
  * ``manifest.json``   one record per file: shape, roles, counts, slug, expectations
  * ``schemas/*.json``  bq load schema (every column STRING, no type inference)
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import sys
import unicodedata
from collections import Counter, defaultdict

# Source exports put newlines inside quoted verbatims; some fields are long.
csv.field_size_limit(min(sys.maxsize, 2**31 - 1))

DEFAULT_BLOCK_REGEX = r"^Q(?P<idx>\d+)_(?P<facet>.+)$"

# Facet-name -> semantic role. Role is what SQL binds to, so a rename upstream
# (`Q1_verbatim` instead of `Q1_qual`) costs one line here, not a pipeline
# rewrite. Unmapped facets are carried through with role "extra".
DEFAULT_ROLE_MAP = {
    "question": "question_text",
    "question_text": "question_text",
    "meta": "meta",
    "label": "meta",
    "type": "q_type",
    "qtype": "q_type",
    "rating_label": "rating_label",
    "scale_label": "rating_label",
    "rating": "rating",
    "score": "rating",
    "selected": "selected",
    "choice": "selected",
    "choices": "selected",
    "qual": "qual",
    "verbatim": "qual",
    "open_end": "qual",
}

# Roles the curated model requires. Absence is a hard error, not a warning:
# without them fct_response cannot be built.
REQUIRED_ROLES = {"question_text", "meta"}


def slugify(name: str) -> str:
    """GCS/BigQuery-safe object name (D8: em-dashes and spaces in filenames)."""
    stem = os.path.splitext(os.path.basename(name))[0]
    stem = unicodedata.normalize("NFKD", stem)
    stem = stem.replace("—", "-").replace("–", "-").replace("’", "")
    stem = re.sub(r"[^A-Za-z0-9]+", "_", stem).strip("_").lower()
    return re.sub(r"_+", "_", stem)


def classify_facets(facets, role_map):
    roles, unmapped = {}, []
    for facet in facets:
        role = role_map.get(facet.lower())
        if role is None:
            role = f"extra_{re.sub(r'[^a-z0-9]+', '_', facet.lower()).strip('_')}"
            unmapped.append(facet)
        roles[facet] = role
    return roles, unmapped


def profile_file(path, block_regex, role_map, entity_key=None):
    pattern = re.compile(block_regex)

    with open(path, newline="", encoding="utf-8-sig") as fh:
        reader = csv.reader(fh)
        try:
            header = next(reader)
        except StopIteration:
            raise ValueError(f"{path}: empty file")

        attrs, blocks = [], defaultdict(dict)
        for pos, col in enumerate(header):
            m = pattern.match(col)
            if m:
                blocks[int(m.group("idx"))][m.group("facet")] = pos
            else:
                attrs.append(col)

        if not blocks:
            raise ValueError(
                f"{path}: no question blocks matched {block_regex!r}. "
                "Pass --block-regex for this export's naming convention."
            )

        # Regularity: every block must carry the same facet set. A ragged file
        # is a source defect -- surface it here rather than let UNPIVOT fail
        # with a column-count error 200 lines into generated SQL.
        facet_sets = {idx: tuple(sorted(f)) for idx, f in blocks.items()}
        shapes = Counter(facet_sets.values())
        ragged = sorted(i for i, f in facet_sets.items() if f != shapes.most_common(1)[0][0])

        # Facet order taken from block 1 so generated SQL keeps source ordering.
        first = min(blocks)
        facets = [f for f, _ in sorted(blocks[first].items(), key=lambda kv: kv[1])]

        indices = sorted(blocks)
        gaps = [i for i in range(1, max(indices) + 1) if i not in blocks]

        key_col = entity_key or (attrs[0] if attrs else header[0])
        if key_col not in header:
            raise ValueError(f"{path}: entity key {key_col!r} not in header")
        key_pos = header.index(key_col)

        rows = 0
        keys, blank_keys, dup_guard = set(), 0, Counter()
        for row in reader:
            if not row or all(v == "" for v in row):
                continue
            rows += 1
            val = row[key_pos].strip() if key_pos < len(row) else ""
            if val:
                keys.add(val)
                dup_guard[val] += 1
            else:
                blank_keys += 1

    roles, unmapped = classify_facets(facets, role_map)
    missing = sorted(REQUIRED_ROLES - set(roles.values()))
    n_questions = len(indices)

    return {
        "source_path": path,
        "source_file": os.path.basename(path),
        "slug": slugify(path),
        "columns_total": len(header),
        "attribute_columns": attrs,
        "n_attributes": len(attrs),
        "facets": facets,
        "n_facets": len(facets),
        "facet_roles": roles,
        "unmapped_facets": unmapped,
        "missing_required_roles": missing,
        "n_questions": n_questions,
        "question_indices": indices,
        "index_gaps": gaps,
        "ragged_blocks": ragged,
        "entity_key": key_col,
        "n_rows": rows,
        "n_entities": len(keys),
        "blank_entity_keys": blank_keys,
        "duplicate_entity_keys": sorted(k for k, c in dup_guard.items() if c > 1),
        # The reconciliation target, derived rather than asserted.
        "expected_fact_rows": rows * n_questions,
        "shape_ok": len(attrs) + n_questions * len(facets) == len(header),
    }


def bq_schema(profile):
    """All columns STRING -- typing happens in staging, never at load time."""
    cols = list(profile["attribute_columns"])
    for idx in profile["question_indices"]:
        cols += [f"Q{idx}_{facet}" for facet in profile["facets"]]
    return [{"name": c, "type": "STRING", "mode": "NULLABLE"} for c in cols]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv_files", nargs="+")
    ap.add_argument("--modality", default="READ",
                    help="Modality stamped on every file in this run (READ/AUDIO/VIDEO)")
    ap.add_argument("--block-regex", default=DEFAULT_BLOCK_REGEX,
                    help="Regex with named groups 'idx' and 'facet'")
    ap.add_argument("--entity-key", default=None,
                    help="Respondent key column (default: first non-block column)")
    ap.add_argument("--role-map", default=None,
                    help="JSON file overriding/extending the facet->role map")
    ap.add_argument("--out", default="build/manifest.json")
    ap.add_argument("--ndjson", default=None,
                    help="Per-file records as NDJSON, for `bq load` into "
                         "ff_00_raw.load_manifest (drives the DQ thresholds)")
    ap.add_argument("--schema-dir", default="build/schemas")
    ap.add_argument("--strict", action="store_true",
                    help="Exit non-zero if any file has a structural problem")
    args = ap.parse_args()

    role_map = dict(DEFAULT_ROLE_MAP)
    if args.role_map:
        with open(args.role_map, encoding="utf-8") as fh:
            role_map.update({k.lower(): v for k, v in json.load(fh).items()})

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    os.makedirs(args.schema_dir, exist_ok=True)

    profiles, problems = [], []
    for path in args.csv_files:
        try:
            p = profile_file(path, args.block_regex, role_map, args.entity_key)
        except ValueError as exc:
            problems.append(str(exc))
            continue
        p["modality"] = args.modality
        profiles.append(p)

        with open(os.path.join(args.schema_dir, f"{p['slug']}.json"), "w",
                  encoding="utf-8") as fh:
            json.dump(bq_schema(p), fh, indent=2)

        for label, val in (("ragged blocks", p["ragged_blocks"]),
                           ("index gaps", p["index_gaps"]),
                           ("blank entity keys", p["blank_entity_keys"]),
                           ("duplicate entity keys", p["duplicate_entity_keys"]),
                           ("missing required roles", p["missing_required_roles"])):
            if val:
                problems.append(f"{p['source_file']}: {label}: {val}")
        if not p["shape_ok"]:
            problems.append(f"{p['source_file']}: column arithmetic does not close")

    # Files sharing a facet signature load into one raw table and unpivot with
    # one generated statement -- this is the grouping, not the question count.
    families = defaultdict(list)
    for p in profiles:
        families["|".join(p["facets"])].append(p["slug"])

    manifest = {
        "modality": args.modality,
        "block_regex": args.block_regex,
        "n_files": len(profiles),
        "facet_families": {k: sorted(v) for k, v in families.items()},
        "totals": {
            "rows": sum(p["n_rows"] for p in profiles),
            "expected_fact_rows": sum(p["expected_fact_rows"] for p in profiles),
            "distinct_entities": len({e for p in profiles for e in [p["slug"]]}) and None,
        },
        "files": profiles,
        "problems": problems,
    }
    # distinct entity count spans files, so it cannot be summed -- left to the
    # warehouse (DQ02 against dim_archetype).
    manifest["totals"].pop("distinct_entities")

    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=2)

    if args.ndjson:
        os.makedirs(os.path.dirname(args.ndjson) or ".", exist_ok=True)
        keep = ("source_file", "slug", "modality", "entity_key", "n_rows",
                "n_questions", "n_attributes", "n_facets", "expected_fact_rows")
        with open(args.ndjson, "w", encoding="utf-8") as fh:
            for p in profiles:
                rec = {k: p[k] for k in keep}
                rec["facets"] = p["facets"]
                fh.write(json.dumps(rec) + "\n")

    print(f"profiled {len(profiles)} file(s) -> {args.out}")
    print(f"  facet families : {len(families)}")
    print(f"  source rows    : {manifest['totals']['rows']:,}")
    print(f"  expected facts : {manifest['totals']['expected_fact_rows']:,}")
    if problems:
        print(f"  PROBLEMS ({len(problems)}):")
        for p in problems:
            print(f"    - {p}")
    if problems and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
