#!/usr/bin/env python3
"""Validate the local ARENA FF source CSVs before any GCP spend.

Checks, in order:
  1. Exactly 12 CSVs present.
  2. Each file's header matches gen_raw_schema.py for its section family.
  3. The 46 persona-attribute columns are identical across all 12 files.
  4. Row counts hit the Gate 1 targets (596 / 398 / 398 = 1,392).
  5. Unique archetype_id count is 398 (Gate 2 target).
  6. Reports embedded-newline pressure (D1) so nobody loads without
     --allow_quoted_newlines.

Exit code 0 = safe to upload. Non-zero = stop and diagnose.

Usage:
  python3 tools/preflight_check.py ["Written Descriptions_2026_08_7"]
"""
import csv
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_raw_schema import ATTRIBUTE_COLUMNS, column_names  # noqa: E402

csv.field_size_limit(10 ** 9)

DEFAULT_SRC = "Written Descriptions_2026_08_7"
EXPECTED_FILES = 12
# section family -> (n_questions, expected total rows across its 4 files)
SECTION_TARGETS = {"2.1": (20, 596), "2.2": (35, 398), "2.3": (36, 398)}
EXPECTED_TOTAL_ROWS = 1392
EXPECTED_PERSONAS = 398

failures = []
warnings = []


def fail(msg):
    failures.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg):
    print(f"  ok    {msg}")


def section_of(filename):
    """Derive the section family ('2.1'/'2.2'/'2.3') from a source filename."""
    m = re.search(r"-(2\.\d)X?\s", filename)
    return m.group(1) if m else None


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    files = sorted(glob.glob(os.path.join(src, "*.csv")))

    print(f"Source: {src}\n")
    print("[1] File inventory")
    if len(files) != EXPECTED_FILES:
        fail(f"expected {EXPECTED_FILES} CSVs, found {len(files)}")
    else:
        ok(f"{EXPECTED_FILES} CSVs found")

    xlsx = glob.glob(os.path.join(src, "*.xlsx"))
    if xlsx:
        warnings.append(f"{len(xlsx)} .xlsx file(s) present - do NOT upload "
                        "(Excel renderings of CSVs already in the set)")

    print("\n[2] Header / schema agreement")
    attr_ref = None
    per_section_rows = {}
    personas = set()
    total_rows = 0
    newline_fields = 0

    for path in files:
        name = os.path.basename(path)
        section = section_of(name)
        if section not in SECTION_TARGETS:
            fail(f"{name}: cannot derive section family from filename")
            continue
        n_questions = SECTION_TARGETS[section][0]

        with open(path, newline="", encoding="utf-8") as fh:
            reader = csv.reader(fh)
            header = next(reader)
            rows = list(reader)

        expected_header = column_names(n_questions)
        if header != expected_header:
            mismatches = [
                (i, got, want)
                for i, (got, want) in enumerate(zip(header, expected_header))
                if got != want
            ]
            fail(f"{name}: header != gen_raw_schema({n_questions}); "
                 f"len {len(header)} vs {len(expected_header)}; "
                 f"first diffs {mismatches[:3]}")
            continue

        if attr_ref is None:
            attr_ref = header[:46]
        elif header[:46] != attr_ref:
            fail(f"{name}: persona-attribute columns differ from first file")

        per_section_rows[section] = per_section_rows.get(section, 0) + len(rows)
        total_rows += len(rows)
        for row in rows:
            personas.add(row[0])
            newline_fields += sum(1 for v in row if "\n" in v)

    if not failures:
        ok(f"all {len(files)} headers match generated schema "
           f"({'/'.join(str(SECTION_TARGETS[s][0]) for s in sorted(SECTION_TARGETS))} questions)")
        ok("46 persona-attribute columns identical across all files")

    print("\n[3] Gate 1 - row counts per section family")
    for section in sorted(SECTION_TARGETS):
        want = SECTION_TARGETS[section][1]
        got = per_section_rows.get(section, 0)
        (ok if got == want else fail)(
            f"section {section}: {got} rows (target {want})")
    (ok if total_rows == EXPECTED_TOTAL_ROWS else fail)(
        f"total: {total_rows} rows (target {EXPECTED_TOTAL_ROWS})")

    print("\n[4] Gate 2 - persona count")
    (ok if len(personas) == EXPECTED_PERSONAS else fail)(
        f"unique archetype_id: {len(personas)} (target {EXPECTED_PERSONAS})")

    print("\n[5] D1 - embedded newlines")
    print(f"  info  {newline_fields} fields contain newlines -> "
          "--allow_quoted_newlines is MANDATORY on load")

    if warnings:
        print("\nWarnings")
        for w in warnings:
            print(f"  warn  {w}")

    print()
    if failures:
        print(f"PREFLIGHT FAILED - {len(failures)} problem(s). Do not upload.")
        return 1
    print("PREFLIGHT PASSED - safe to stage to GCS.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
