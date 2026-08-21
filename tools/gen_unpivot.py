#!/usr/bin/env python3
"""Emit the BigQuery UNPIVOT statement that turns a wide raw section table long.

One source row of 46 + 7N columns becomes 1 persona row + N fact rows. See
BIGQUERY_MIGRATION_PLAN.md Section 7.1.

The plan's snippet emits only the IN-list body; this emits the complete
CREATE OR REPLACE TABLE statement so the output is directly executable:

  python3 tools/gen_unpivot.py 35 | bq query --use_legacy_sql=false

Usage:
  python3 tools/gen_unpivot.py 35                    # full statement
  python3 tools/gen_unpivot.py 35 --in-list-only     # just the IN list
  python3 tools/gen_unpivot.py 20 --section 2.1      # override section label
"""
import argparse
import sys

# n_questions -> section code (Plan Section 1.1)
SECTION_BY_N = {20: "2.1", 35: "2.2", 36: "2.3"}
BLOCK_FIELDS = ["question", "meta", "type", "rating_label", "rating", "selected", "qual"]
# UNPIVOT output column names, in the same order as BLOCK_FIELDS
OUTPUT_FIELDS = ["question_text", "meta", "q_type", "rating_label", "rating", "selected", "qual"]


def in_list(n_questions, indent="    "):
    """The UNPIVOT FOR ... IN (...) body: one tuple per question slot."""
    lines = []
    for i in range(1, n_questions + 1):
        cols = ", ".join(f"Q{i}_{f}" for f in BLOCK_FIELDS)
        lines.append(f"{indent}({cols}) AS {i}")
    return ",\n".join(lines)


def statement(n_questions, section_code, raw_dataset, stg_dataset, suffix):
    raw_table = f"raw_read_{suffix}"
    stg_table = f"stg_response_{suffix}"
    return f"""-- Section {section_code}: {n_questions} question blocks -> {n_questions} fact rows per source row.
CREATE OR REPLACE TABLE `{stg_dataset}.{stg_table}` AS
SELECT
  archetype_id,
  LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\\.csv$')) AS run_id,
  q_idx, {', '.join(OUTPUT_FIELDS)}
FROM `{raw_dataset}.{raw_table}`
UNPIVOT (
  ({', '.join(OUTPUT_FIELDS)})
  FOR q_idx IN (
{in_list(n_questions, indent='    ')}
  )
);"""


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("n_questions", type=int, help="20, 35 or 36")
    parser.add_argument("--in-list-only", action="store_true",
                        help="emit only the IN-list body")
    parser.add_argument("--section", help="section code override (default derived from n)")
    parser.add_argument("--raw-dataset", default="ff_00_raw")
    parser.add_argument("--stg-dataset", default="ff_10_staging")
    parser.add_argument("--suffix", help="table suffix override, e.g. s22")
    args = parser.parse_args()

    if args.n_questions < 1:
        parser.error("n_questions must be positive")

    section_code = args.section or SECTION_BY_N.get(args.n_questions)
    if section_code is None:
        parser.error(f"unknown section size {args.n_questions}; pass --section explicitly")

    if args.in_list_only:
        print(in_list(args.n_questions))
        return

    suffix = args.suffix or "s" + section_code.replace(".", "")
    print(statement(args.n_questions, section_code,
                    args.raw_dataset, args.stg_dataset, suffix))


if __name__ == "__main__":
    main()
