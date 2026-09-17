#!/usr/bin/env python3
"""Render the UNPIVOT statement sp_unpivot_survey would generate.

Same algorithm as sql/10_sp_unpivot_survey.sql, driven by the manifest
instead of INFORMATION_SCHEMA. Two uses:

  1. Review the generated SQL before any GCP project exists.
  2. Diff against the procedure's dry-run output to confirm the in-database
     path and the local path agree.

Usage::

    python3 tools/render_unpivot.py build/manifest_read.json --family-index 0
"""

from __future__ import annotations

import argparse
import json


def render(facets, indices, raw_table, out_table, role_map, has_source_file=True):
    decl = ", ".join(f"v_{f}" for f in facets)
    select = ",\n    ".join(f"v_{f} AS {role_map.get(f, f)}" for f in facets)
    in_list = ",\n    ".join(
        "({}) AS {}".format(", ".join(f"Q{i}_{f}" for f in facets), i)
        for i in indices
    )
    run_id = (r"LOWER(REGEXP_EXTRACT(_source_file, r'([^/]+)\.csv$'))"
              if has_source_file else "CAST(NULL AS STRING)")
    return f"""CREATE OR REPLACE TABLE `{out_table}` AS
SELECT
    * EXCEPT({decl}),
    {select},
    q_idx,
    {run_id} AS run_id
FROM `{raw_table}`
UNPIVOT (({decl}) FOR q_idx IN (
    {in_list}
))"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--file", default=None, help="slug to render (default: first)")
    ap.add_argument("--raw-dataset", default="ff_00_raw")
    ap.add_argument("--out-dataset", default="ff_10_staging")
    args = ap.parse_args()

    with open(args.manifest, encoding="utf-8") as fh:
        m = json.load(fh)

    prof = next((p for p in m["files"] if p["slug"] == args.file), m["files"][0])
    print(f"-- source: {prof['source_file']}")
    print(f"-- {prof['n_questions']} blocks x {prof['n_facets']} facets "
          f"= {prof['expected_fact_rows']:,} expected fact rows\n")
    print(render(prof["facets"], prof["question_indices"],
                 f"{args.raw_dataset}.raw_{prof['slug']}",
                 f"{args.out_dataset}.stg_{prof['slug']}",
                 prof["facet_roles"]))


if __name__ == "__main__":
    main()
