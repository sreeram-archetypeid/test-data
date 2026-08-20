#!/usr/bin/env python3
"""Emit a BigQuery schema string for an ARENA FF raw section table.

Every column is STRING by design (see BIGQUERY_MIGRATION_PLAN.md Section 5.2):
type inference is inconsistent across the three section families and would give
the raw layer a different shape per file. All casting happens in 10_staging
where the rules are visible and testable.

Layout: 46 persona-attribute columns, then N repeating 7-column question blocks.
  Q{n}_question, Q{n}_meta, Q{n}_type, Q{n}_rating_label,
  Q{n}_rating, Q{n}_selected, Q{n}_qual

Usage:
  python3 tools/gen_raw_schema.py 35              # -> archetype_id:STRING,...
  python3 tools/gen_raw_schema.py 35 --json       # -> BigQuery JSON schema
  python3 tools/gen_raw_schema.py 35 --external-ddl \\
      --dataset ff_00_raw --table ext_read_s22 \\
      --uris 'gs://bucket/arena-ff/read/v1/*_2_2*.csv'   # -> CREATE EXTERNAL TABLE

The --external-ddl mode declares every column explicitly. This matters: an
external table created without a column list lets BigQuery autodetect types,
which silently breaks the all-STRING guarantee the raw layer depends on.
"""
import argparse
import json
import sys

ATTRIBUTE_COLUMNS = [
    "archetype_id", "group_name", "sample_name", "archetype_title",
    "archetype_name", "archetype_age_range", "archetype_gender",
    "archetype_race", "archetype_marital_status", "archetype_children_status",
    "archetype_children", "archetype_education_level",
    "archetype_field_of_study", "archetype_occupation",
    "archetype_income_range", "archetype_political_affiliation",
    "archetype_religious_affiliation", "archetype_location",
    "archetype_location_type", "archetype_hobbies_and_interests",
    "archetype_lived_experience", "archetype_nps_score",
    "archetype_persona_summary", "archetype_goals_and_motivations",
    "archetype_audience_insights_triggers", "archetype_psychographic_values",
    "archetype_psychographic_interests", "archetype_psychographic_lifestyle",
    "archetype_purchasing_behaviors", "archetype_challenges_pain_points",
    "archetype_decision_making_steps", "archetype_triggers_to_switch",
    "archetype_product_expectations", "archetype_product_influencers",
    "archetype_media_channels", "archetype_psychometric_vector_name",
    "archetype_psychometric_vector_summary",
    "archetype_psychometric_vector_characteristics",
    "archetype_psychometric_vector_emotions",
    "archetype_why_psychometric_vector_fits", "archetype_group_dynamics",
    "archetype_adoption_category_name", "archetype_adoption_rationale",
    "archetype_composite_attitude_score_summary", "archetype_nps_summary",
    "archetype_lived_experience_summary",
]

QUESTION_BLOCK_SUFFIXES = [
    "question", "meta", "type", "rating_label", "rating", "selected", "qual",
]

# n_questions per section family, for validation (Plan Section 1.1).
KNOWN_SECTION_SIZES = {20: "2.1", 35: "2.2", 36: "2.3"}


def column_names(n_questions):
    """Return the full ordered column list for a section with n_questions."""
    cols = list(ATTRIBUTE_COLUMNS)
    for q in range(1, n_questions + 1):
        cols.extend(f"Q{q}_{suffix}" for suffix in QUESTION_BLOCK_SUFFIXES)
    return cols


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("n_questions", type=int,
                        help="number of question blocks (20, 35 or 36)")
    parser.add_argument("--json", action="store_true",
                        help="emit BigQuery JSON schema instead of the inline string")
    parser.add_argument("--external-ddl", action="store_true",
                        help="emit a CREATE OR REPLACE EXTERNAL TABLE statement "
                             "with all columns pinned to STRING")
    parser.add_argument("--dataset", default="ff_00_raw",
                        help="dataset for --external-ddl (default: ff_00_raw)")
    parser.add_argument("--table", help="table name for --external-ddl")
    parser.add_argument("--uris", help="GCS URI glob for --external-ddl")
    args = parser.parse_args()

    if args.external_ddl and not (args.table and args.uris):
        parser.error("--external-ddl requires --table and --uris")

    if args.n_questions < 1:
        parser.error("n_questions must be positive")
    if args.n_questions not in KNOWN_SECTION_SIZES:
        print(f"warning: {args.n_questions} is not a known section size "
              f"({sorted(KNOWN_SECTION_SIZES)}); emitting anyway",
              file=sys.stderr)

    cols = column_names(args.n_questions)

    if args.external_ddl:
        col_ddl = ",\n".join(f"  {c} STRING" for c in cols)
        print(
            f"CREATE OR REPLACE EXTERNAL TABLE `{args.dataset}.{args.table}` (\n"
            f"{col_ddl}\n"
            f")\nOPTIONS (\n"
            f"  format = 'CSV',\n"
            f"  uris = ['{args.uris}'],\n"
            f"  skip_leading_rows = 1,\n"
            f"  allow_quoted_newlines = true,\n"
            f"  encoding = 'UTF-8'\n"
            f");"
        )
    elif args.json:
        print(json.dumps([{"name": c, "type": "STRING", "mode": "NULLABLE"}
                          for c in cols], indent=2))
    else:
        print(",".join(f"{c}:STRING" for c in cols))


if __name__ == "__main__":
    main()
