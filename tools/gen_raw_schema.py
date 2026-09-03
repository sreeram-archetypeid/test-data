#!/usr/bin/env python3
"""
Generate the raw-landing DDL for the READ section families.

Emits, per family, an external table over the staged GCS objects plus a
materialised copy that captures `_FILE_NAME`. Everything is typed STRING.

Why STRING for every column: autodetect types `archetype_nps_score` as INT64 in
some files and STRING in others, and would give the three families mutually
incompatible schemas. Casting belongs in `10_staging`, where the rules are
visible and testable.

Why external table then materialise: `_FILE_NAME` is only available on external
tables, and `run_id` is derived from it. Loading directly would lose the
provenance that `dim_run` and `is_primary_run` depend on.

Why read the real CSV header instead of synthesising Q1..Qn from a count: a
source column change then fails loudly here rather than silently misaligning the
UNPIVOT four steps later.

Usage
-----
    python3 tools/gen_raw_schema.py s22          # print DDL for one family
    python3 tools/gen_raw_schema.py --all        # write every family to sql/

The generated SQL carries ${PROJECT_ID}, ${DS_RAW} and ${GCS_PREFIX}
placeholders; tools/land_raw.sh substitutes them from config.env at run time.
"""

import csv
import os
import re
import sys

# Section 1.4 was delivered separately from sections 2.1-2.3, so the source is a
# LIST of directories. Override with SRC="a:b".
SRC_DIRS = os.environ.get(
    "SRC", "Written Descriptions_2026_08_7:Written Descriptions_2026_08_18"
).split(":")

# family -> (section code, questions, columns, source files, attribute columns)
#
# The last two used to be module-level constants, which was fine while every
# family had the same shape. Section 1.4 has neither: it shipped 2 files rather
# than 4, and carries 80 attribute columns rather than 46 -- the same 46 as a
# strict prefix, plus a 34-column aat_* diagnostics block. Left as constants,
# both would have failed a check that was measuring the wrong thing.
FAMILIES = {
    "s21": ("2.1", 20, 186, 4, 46),
    "s22": ("2.2", 35, 291, 4, 46),
    "s23": ("2.3", 36, 298, 4, 46),
    "s14": ("1.4",  4, 108, 2, 80),
}

BLOCK_COLS = 7          # question, meta, type, rating_label, rating, selected, qual

# Captures BOTH halves of the section number. Pinned to 2.x, section 1.4 files
# were rejected outright; and the lower-case 'x' matters -- the 2.x files carry
# "2.1X" but the 1.4 delivery carries "1.4x", and (X?) matches the empty string
# rather than failing, which silently drops the replicate marker.
SRC_NAME_RE = re.compile(r"^3-ARENA-FF-([GS])-(gr[12])-([12])\.([1-4])([Xx]?)")
BQ_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def staged_object_name(stem):
    """Mirror tools/slugify_upload.sh: source stem -> staged GCS object name."""
    m = SRC_NAME_RE.match(stem)
    if not m:
        raise SystemExit(f"ERROR: unrecognised source filename: {stem}")
    creative, group, major, section, replicate = m.groups()
    return (f"read_{creative.lower()}_{group}"
            f"_s{major}_{section}{replicate.lower()}.csv")


def collect(family):
    """Return (sorted object names, header) for one section family."""
    section, _, _, n_files, _ = FAMILIES[family]
    major, minor = section.split(".")

    paths = []
    for d in SRC_DIRS:
        if not os.path.isdir(d):
            raise SystemExit(f"ERROR: source directory not found: {d}")
        for name in sorted(os.listdir(d)):
            if not name.endswith(".csv"):
                continue
            m = SRC_NAME_RE.match(name[:-4])
            # Match on BOTH halves. Matching the minor digit alone would pull
            # section 1.4's files into a hypothetical 2.4 family, and vice versa.
            if m and m.group(3) == major and m.group(4) == minor:
                paths.append(os.path.join(d, name))
    paths.sort()

    if len(paths) != n_files:
        raise SystemExit(
            f"ERROR: section {section}: found {len(paths)} source files, expected {n_files}"
        )

    headers = []
    for p in paths:
        with open(p, newline="", encoding="utf-8") as fh:
            headers.append(next(csv.reader(fh)))

    base = headers[0]
    for p, h in zip(paths[1:], headers[1:]):
        if h != base:
            diff = next(
                (i for i, (a, b) in enumerate(zip(base, h)) if a != b), len(base)
            )
            raise SystemExit(
                f"ERROR: header mismatch in {p} at column {diff}. "
                "One external table cannot span differing schemas."
            )

    _, n_questions, n_cols, _, attr_cols = FAMILIES[family]
    if len(base) != n_cols:
        raise SystemExit(
            f"ERROR: section {section}: header has {len(base)} columns, expected {n_cols}"
        )
    if len(base) != attr_cols + BLOCK_COLS * n_questions:
        raise SystemExit(
            f"ERROR: section {section}: {len(base)} columns is not "
            f"{attr_cols} + {BLOCK_COLS}x{n_questions}"
        )

    dupes = sorted({c for c in base if base.count(c) > 1})
    if dupes:
        raise SystemExit(f"ERROR: duplicate column names: {dupes}")
    bad = [c for c in base if not BQ_NAME_RE.match(c)]
    if bad:
        raise SystemExit(f"ERROR: column names invalid for BigQuery: {bad}")

    objects = sorted(staged_object_name(os.path.basename(p)[:-4]) for p in paths)
    return objects, base


def render(family):
    objects, header = collect(family)
    section, n_questions, n_cols, n_files, attr_cols = FAMILIES[family]

    cols = ",\n".join(f"  {c} STRING" for c in header)
    uris = ",\n".join(f"    '${{GCS_PREFIX}}/{o}'" for o in objects)

    return f"""\
-- Generated by tools/gen_raw_schema.py -- do not edit by hand.
--
-- Section {section}: {n_questions} questions, {n_cols} columns
--                    ({attr_cols} persona attributes + {BLOCK_COLS} x {n_questions} question blocks),
--                    {n_files} source files.
--
-- allow_quoted_newlines is mandatory: 8,957 verbatim fields contain embedded
-- newlines, and without it every file shreds into garbage rows.

CREATE OR REPLACE EXTERNAL TABLE `${{PROJECT_ID}}.${{DS_RAW}}.ext_read_{family}` (
{cols}
)
OPTIONS (
  format = 'CSV',
  uris = [
{uris}
  ],
  skip_leading_rows = 1,
  allow_quoted_newlines = true,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8',
  max_bad_records = 0
);

-- Materialise so raw is immutable and `_FILE_NAME` is captured as data.
-- `run_id` is derived from _source_file downstream, which is what makes the
-- 2.1X replicate runs distinguishable.

CREATE OR REPLACE TABLE `${{PROJECT_ID}}.${{DS_RAW}}.raw_read_{family}` AS
SELECT
  *,
  _FILE_NAME          AS _source_file,
  CURRENT_TIMESTAMP() AS _loaded_at
FROM `${{PROJECT_ID}}.${{DS_RAW}}.ext_read_{family}`;
"""


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)

    if args[0] == "--all":
        os.makedirs("sql", exist_ok=True)
        for family in FAMILIES:
            path = os.path.join("sql", f"01_raw_{family}.sql")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(render(family))
            print(f"wrote {path}")
        return

    family = args[0]
    if family not in FAMILIES:
        raise SystemExit(f"ERROR: unknown family {family!r}; expected one of {list(FAMILIES)}")
    sys.stdout.write(render(family))


if __name__ == "__main__":
    main()
