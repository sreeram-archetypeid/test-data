"""
Orchestrator: manifest + Gate 1 answers -> xlsx banner.

Run:  python3 pipeline/run.py <drop_dir> <manifest.json> <out.xlsx>
"""
import json, sys, datetime
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build import unpivot, clean, build_questions, mark_primary          # noqa: E402
from banner import resolve_cuts, compute_banner                           # noqa: E402

from openpyxl import Workbook
from openpyxl.styles import Font, Alignment

# ---------------------------------------------------------------------------
# GATE 1 ANSWERS.  In the cloud build these come from the approval Sheet and
# land in svy_config.  Here they are explicit so it is obvious which decisions
# are human judgement rather than inference.
# ---------------------------------------------------------------------------
GATE1 = {
    "scale_direction": "1_IS_BEST",
    "sentinel_min_code": 90,
    "dedup_policy": "PRIMARY_ONLY",
    "multiselect_delimiter": "|",
    "banner_cuts": [
        {"name": "GENDER", "kind": "attribute",
         "column": "archetype_gender", "normalize": "titlecase"},
        {"name": "AGE", "kind": "attribute",
         "column": "archetype_age_range", "normalize": "age_band",
         "bands": ["13-17", "18-24", "25-34", "35-44", "45-54", "55-64"]},
        {"name": "RACE", "kind": "attribute",
         "column": "archetype_race", "normalize": "titlecase"},
        {"name": "RELATIONSHIP", "kind": "attribute",
         "column": "archetype_marital_status", "normalize": "titlecase"},
    ],
}

METRIC_ROWS = [("N", "n", "0"), ("TB %", "TB", "0.0%"), ("T2B %", "T2B", "0.0%"),
               ("B2B%", "B2B", "0.0%"), ("BOT%", "BOT", "0.0%"),
               ("MEAN", "MEAN", "0.00")]


def column_order(banner_rows, gate1):
    """Total first, then each configured cut's values in a stable order."""
    cols = [("TOTAL", "Total")]
    seen = {("TOTAL", "Total")}
    for cut in gate1["banner_cuts"]:
        vals = sorted({r["cut_value"] for r in banner_rows
                       if r["cut_name"] == cut["name"]})
        for v in vals:
            key = (cut["name"], v)
            if key not in seen:
                cols.append(key)
                seen.add(key)
    return cols


def render(banner_rows, questions, cols, out_path, meta):
    wb = Workbook()
    ws = wb.active
    ws.title = "Banner"
    bold = Font(bold=True)

    idx = defaultdict(dict)
    for r in banner_rows:
        idx[(r["question_code"], r["question_text"])][(r["cut_name"], r["cut_value"])] = r

    row = 1
    for k, v in meta.items():
        ws.cell(row=row, column=1, value=k).font = bold
        ws.cell(row=row, column=2, value=v)
        row += 1
    row += 1

    table_no = 0
    for qkey in sorted(idx, key=lambda k: (k[0], k[1])):
        q = questions[qkey]
        cells = idx[qkey]
        total = cells.get(("TOTAL", "Total"))
        if not total:
            continue
        table_no += 1

        ws.cell(row=row, column=1, value="#page"); row += 1
        ws.cell(row=row, column=1, value=f"Table {table_no}").font = bold; row += 1
        label = f"{qkey[0]}. {qkey[1]}" if qkey[0] else qkey[1]
        ws.cell(row=row, column=1, value=label).font = bold; row += 1
        row += 1
        ws.cell(row=row, column=1, value="Base: Total Respondents"); row += 1
        row += 1

        # banner group header row -- sparse, written only at each group's start
        grp_row = row
        c, prev = 2, None
        for cut_name, _ in cols:
            if cut_name != prev:
                ws.cell(row=grp_row, column=c, value=cut_name).font = bold
                prev = cut_name
            c += 1
        row += 1

        # column label row
        c = 2
        for _, cut_value in cols:
            cell = ws.cell(row=row, column=c, value=cut_value)
            cell.font = bold
            cell.alignment = Alignment(horizontal="center", wrap_text=True)
            c += 1
        row += 1

        # What gets emitted depends on how the question can legitimately be
        # tabulated, not on whether an option code happens to exist.
        kind = q["tabulation"]
        emit = METRIC_ROWS if kind in ("SCALE", "NUMERIC") else [("N", "n", "0")]

        for label_txt, field, fmt in emit:
            ws.cell(row=row, column=1, value=label_txt)
            c = 2
            for key in cols:
                r = cells.get(key)
                if r and field in r:
                    cell = ws.cell(row=row, column=c, value=r[field])
                    cell.number_format = fmt
                c += 1
            row += 1

        if kind == "SELECT":
            for code, lbl in q["options"]:
                ws.cell(row=row, column=1, value=f"% {code}. {lbl}")
                c = 2
                for key in cols:
                    r = cells.get(key)
                    if r and code in r.get("options", {}):
                        cell = ws.cell(row=row, column=c, value=r["options"][code])
                        cell.number_format = "0.0%"
                    c += 1
                row += 1
            if q["max_selections"] > 1:
                ws.cell(row=row, column=1,
                        value="(multi-select: percentages can sum >100%)")
                row += 1
        elif kind == "OPEN":
            ws.cell(row=row, column=1,
                    value="OE — verbatims not tabulated here"); row += 1
        row += 1

    ws.column_dimensions["A"].width = 64
    for i in range(2, len(cols) + 2):
        ws.column_dimensions[ws.cell(row=1, column=i).column_letter].width = 13

    # a tidy sheet, so every rendered number can be traced to its source row
    ws2 = wb.create_sheet("Tidy")
    ws2.append(["question_code", "question_text", "cut_name", "cut_value",
                "n", "TB", "T2B", "B2B", "BOT", "MEAN", "scale_max"])
    for r in banner_rows:
        ws2.append([r["question_code"], r["question_text"], r["cut_name"],
                    r["cut_value"], r["n"], r.get("TB"), r.get("T2B"),
                    r.get("B2B"), r.get("BOT"), r.get("MEAN"), r.get("scale_max")])
    wb.save(out_path)
    return table_no


def main(drop_dir, manifest_path, out_path):
    manifest = json.loads(Path(manifest_path).read_text())
    if manifest["status"] == "REFUSED":
        raise SystemExit(f"discovery refused: {manifest['refusals']}")

    long_rows, respondents, roles, _ = unpivot(drop_dir, manifest)
    print(f"unpivot        {len(long_rows):>8,} long rows "
          f"(expected {manifest['expected_long_rows_total']:,})")
    assert len(long_rows) == manifest["expected_long_rows_total"], \
        "row count does not match the derived expectation"

    rows = clean(long_rows, roles, GATE1)
    print(f"clean          {len(rows):>8,} answered rows")

    questions = build_questions(rows, GATE1)
    print(f"questions      {len(questions):>8,} distinct identities")

    rows = mark_primary(rows, GATE1)
    print(f"respondents    {len({r['respondent_id'] for r in rows}):>8,} distinct")

    membership = resolve_cuts(respondents, rows, GATE1, GATE1["sentinel_min_code"])
    banner_rows = compute_banner(rows, questions, membership, GATE1)
    print(f"banner         {len(banner_rows):>8,} tidy rows")

    cols = column_order(banner_rows, GATE1)
    print(f"columns        {len(cols):>8,} banner columns")

    n = render(banner_rows, questions, cols, out_path, {
        "PROJECT:": manifest["drop_id"],
        "GENERATED:": datetime.date.today().isoformat(),
        "SCALE CONVENTION:": GATE1["scale_direction"],
        "BASE:": "Primary run per respondent per question",
    })
    print(f"rendered       {n:>8,} tables -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
