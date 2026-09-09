#!/usr/bin/env python3
"""Stage 0 -- discover every export in a folder tree and work out how they relate.

Nothing downstream hardcodes a filename any more. This stage walks the data
directory, parses study / instrument / panel / build / date / run out of each
filename, measures each file's shape, and writes a registry the other stages
read.

It also works out the relationships that matter for version testing:

  * same panel, different build      -> a VERSION pair. Same instrument, same
                                        cohort definition, new generation run.
                                        Differences are what you want to measure.
  * same build, different panel      -> siblings in one wave (AD / K3 / K9).
  * different instrument, same wording -> a REPLICATION pair (TSR vs HTR).
  * same panel, same build, different run_seq -> a pure REPLICATE. The cleanest
                                        possible noise measurement: nothing
                                        changed but the random seed.

The registry is plain JSON. If a filename does not follow either convention,
edit `conf/registry.json` by hand and this stage will use it instead of
guessing -- that override is the intended escape hatch, not a workaround.

  python3 tools/00_discover.py --data /path/to/exports --out out
"""
from __future__ import annotations

import argparse
import json
import os

import htr_lib as L

REQUIRED_COLUMNS = ("archetype_id", "group_name")


def scan(data_dir):
    exports, skipped = [], []
    for root, _dirs, files in os.walk(data_dir):
        if os.sep + ".git" in root:
            continue
        for fn in sorted(files):
            if not fn.lower().endswith(".csv"):
                continue
            path = os.path.join(root, fn)
            meta = L.parse_export_name(fn)
            if not meta:
                skipped.append(dict(path=path, reason="filename does not match either convention"))
                continue
            try:
                hdr, rows = L.read_csv(path)
            except (UnicodeDecodeError, OSError) as exc:
                skipped.append(dict(path=path, reason=f"unreadable: {exc}"))
                continue
            if not hdr or not all(c in hdr for c in REQUIRED_COLUMNS):
                skipped.append(dict(path=path, reason="not a persona export (no archetype_id)"))
                continue
            positions = L.question_positions(hdr)
            attrs, aat = L.attribute_columns(hdr)
            wording = sorted({L.norm_text(L.modal(rows, p, "question")[0]) for p in positions} - {""})
            exports.append(dict(
                run_id=L.run_id(meta), panel_code=L.panel_code(meta),
                path=os.path.relpath(path, data_dir), **meta,
                n_personas=len(rows), n_columns=len(hdr), n_questions=len(positions),
                n_attr_columns=len(attrs), n_aat_columns=len(aat),
                expected_fact_rows=len(rows) * len(positions),
                has_option_codes=any(
                    L.split_option(part)[0] is not None
                    for p in positions for r in rows[:20]
                    for part in L.split_multi(L.cell(r, p, "selected"))),
                question_wording=wording))
    return exports, skipped


def relate(exports):
    rels = []
    for i in range(len(exports)):
        for j in range(i + 1, len(exports)):
            a, b = exports[i], exports[j]
            shared = set(a["question_wording"]) & set(b["question_wording"])
            overlap = len(shared) / max(min(len(a["question_wording"]), len(b["question_wording"])), 1)
            if a["panel_code"] == b["panel_code"] and a["build"] != b["build"]:
                kind = "version"
            elif (a["panel_code"] == b["panel_code"] and a["build"] == b["build"]
                  and a["run_seq"] != b["run_seq"]):
                kind = "replicate"
            elif a["build"] == b["build"] and a["instrument"] == b["instrument"]:
                kind = "wave_sibling"
            elif overlap >= 0.5:
                kind = "replication"          # different instrument, same questions
            else:
                continue
            rels.append(dict(kind=kind, a=a["run_id"], b=b["run_id"],
                             a_panel=a["panel_code"], b_panel=b["panel_code"],
                             a_build=a["build"], b_build=b["build"],
                             shared_wording=len(shared),
                             shared_wording_share=round(overlap, 3),
                             comparable=int(kind in ("version", "replicate")
                                            or overlap >= 0.5)))
    return rels


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="out")
    ap.add_argument("--registry", default="conf/registry.json",
                    help="hand-written override; used as-is when it exists")
    a = ap.parse_args()

    if os.path.exists(a.registry):
        with open(a.registry, encoding="utf-8") as fh:
            reg = json.load(fh)
        print(f"using hand-written registry {a.registry} ({len(reg['exports'])} exports)")
        exports, skipped = reg["exports"], reg.get("skipped", [])
    else:
        exports, skipped = scan(a.data)
    if not exports:
        L.die(f"no persona exports found under {a.data}")

    rels = relate(exports)
    os.makedirs(a.out, exist_ok=True)
    reg = dict(data_dir=os.path.abspath(a.data), exports=exports,
               relationships=rels, skipped=skipped)
    with open(os.path.join(a.out, "registry.json"), "w", encoding="utf-8") as fh:
        json.dump(reg, fh, indent=1)

    print(L.banner("ABR stage 0 -- discovered exports"))
    print(f"  {'run_id':<26}{'panel':<10}{'build':<10}{'date':<7}{'run':>4}"
          f"{'n':>6}{'Qs':>5}{'codes':>7}  file")
    for e in sorted(exports, key=lambda e: (e["instrument"], e["panel_code"], e["build"])):
        print(f"  {e['run_id']:<26}{e['panel_code']:<10}{e['build']:<10}"
              f"{e['export_date'] or '-':<7}{e['run_seq']:>4}{e['n_personas']:>6}"
              f"{e['n_questions']:>5}{('yes' if e['has_option_codes'] else 'no'):>7}  "
              f"{os.path.basename(e['path'])[:44]}")
    print(f"\n  totals: {len(exports)} exports, {sum(e['n_personas'] for e in exports)} personas, "
          f"{sum(e['expected_fact_rows'] for e in exports):,} fact rows")

    if rels:
        print("\n  relationships:")
        order = {"replicate": 0, "version": 1, "wave_sibling": 2, "replication": 3}
        for r in sorted(rels, key=lambda r: (order.get(r["kind"], 9), r["a"])):
            note = {
                "replicate": "same instrument, same build, different run -- pure noise measurement",
                "version": "same panel, different build -- THIS is a version test",
                "wave_sibling": "same wave, different panel",
                "replication": "different instrument, shared wording -- cross-wave replication",
            }[r["kind"]]
            print(f"    {r['kind']:<13} {r['a']:<26} <-> {r['b']:<26} "
                  f"shared wording {r['shared_wording']:>3} ({100*r['shared_wording_share']:.0f}%)")
            print(f"    {'':<13} {note}")
    versions = [r for r in rels if r["kind"] in ("version", "replicate")]
    if not versions:
        print("\n  NO version or replicate pairs in this folder. Version testing needs at least")
        print("  two builds of the same panel; drop the second export in and re-run stage 0.")
    if skipped:
        print(f"\n  skipped {len(skipped)} file(s):")
        for s in skipped[:8]:
            print(f"    {os.path.basename(s['path'])[:50]:<52} {s['reason']}")
        print("  add them to conf/registry.json by hand if any of these are real exports.")
    print(f"\n  wrote {a.out}/registry.json")


if __name__ == "__main__":
    main()
