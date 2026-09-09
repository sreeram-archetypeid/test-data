#!/usr/bin/env python3
"""Stage 2 -- land the wide exports as a long, typed, joinable model.

One source row of 661 columns becomes 1 persona row + 1 aat row + N fact rows.
That is the whole point of the exercise: after this, "what is top box on appeal"
is `WHERE meta = 'POSTAPPEAL'` instead of knowing that appeal happens to be Q13
in the adult file and does not exist in the kids files.

Writes to <out>/landed:
  dim_archetype.csv        one row per persona, raw attributes + derived
  dim_aat.csv              the aat_* block, flattened and typed, + diagnostics JSON
  dim_question.csv         stable question identity (panel, meta, text) -> question_key
  dim_question_option.csv  every observed option: code, printed point, label, n
  fct_response.csv         one row per persona x question -- the analysis grain
  fct_response_option.csv  multi-selects exploded, one row per chosen option
  load/                    BigQuery schemas, GCS staging, external tables, unpivot SQL, gate

Then reconciles against out/manifest.json and exits non-zero on any mismatch.

  python3 tools/02_land.py --data /home/user/abr --out out
"""
from __future__ import annotations

import argparse
import json
import os
import re

import htr_lib as L

PANEL_FILES = [
    ("AD", "adults", "42p.0.0-ABR-HTR-09-01-1 — Results.csv"),
    ("K3", "kids_4_6", "42p.0.0-ABR-HTR-K3-09-01-1 — Results.csv"),
    ("K9", "kids_7_12", "42p.0.0-ABR-HTR-K9-09-01-1 — Results.csv"),
]
WAVE = "42p.0.0-ABR-HTR-09-01-1"

# aat_* columns that are numeric scores despite arriving as strings.
AAT_NUMERIC = (
    "aat_pre_concept_interest_pct", "aat_post_concept_interest_pct", "aat_interest_delta",
    "aat_text_prose_friction", "aat_visual_execution_potential", "aat_pact_fulfillment_score",
    "aat_polarization_risk", "aat_organic_evangelism", "aat_playability_score",
)
# aat_* columns that are ordered bands.
AAT_BANDS = {
    "aat_viral_memeability": ["Low", "Med", "High"],
    "aat_top_box_category": ["Definitely Not Interested", "Probably Not Interested",
                             "Probably Interested", "Definitely Interested"],
    "aat_opening_weekend_intent": ["Never Watch", "Wait for Streaming", "Opening Weekend Theater"],
}


def flatten_json(obj, prefix="aatj"):
    out = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = f"{prefix}_{L.slug(k, 40)}"
            if isinstance(v, (dict, list)):
                out.update(flatten_json(v, key))
            else:
                out[key] = "" if v is None else str(v)
    elif isinstance(obj, list):
        out[prefix] = " | ".join(str(x) for x in obj if not isinstance(x, (dict, list)))
    return out


def land_panel(path, panel, cohort):
    hdr, rows = L.read_csv(path)
    attr_cols, aat_cols = L.attribute_columns(hdr)
    positions = L.question_positions(hdr)
    src = os.path.basename(path)

    # ---- dim_question -------------------------------------------------------
    questions = []
    for pos in positions:
        meta, meta_var = L.modal(rows, pos, "meta")
        text, text_var = L.modal(rows, pos, "question")
        qtype, type_var = L.modal(rows, pos, "type")
        questions.append(dict(
            question_key=L.qkey(panel, meta, text), panel=panel, cohort=cohort,
            source_file=src, q_position=pos, meta=meta, question_text=text,
            question_text_norm=L.norm_text(text), q_type=qtype,
            channel=("open_end" if qtype == L.TYPE_OPEN_END else
                     "multi_select" if qtype == L.TYPE_MULTI else "single_select"),
            meta_variants=meta_var, text_variants=text_var, type_variants=type_var))
    # A duplicated question item collides on identity. Do not merge and do not
    # drop: suffix the key, record the parent, and measure how often the two
    # answers agree. AD Q32/Q33 are byte-identical statements answered
    # identically by 272 of 273 personas -- reporting both double-counts the
    # battery, and the disagreement rate is a free intra-interview stability read.
    by_identity = {}
    for q in questions:
        by_identity.setdefault(q["question_key"], []).append(q)
    for key, group in by_identity.items():
        if len(group) == 1:
            q = group[0]
            q["duplicate_of_key"] = ""
            q["duplicate_ordinal"] = 1
            q["duplicate_agreement_pct"] = None
            continue
        group.sort(key=lambda q: q["q_position"])
        first = group[0]
        for i, q in enumerate(group, start=1):
            q["duplicate_ordinal"] = i
            if i > 1:
                q["question_key"] = f"{key}_d{i}"
                q["duplicate_of_key"] = key
                agree = sum(1 for r in rows
                            if L.cell(r, q["q_position"], "selected") == L.cell(r, first["q_position"], "selected")
                            and L.cell(r, first["q_position"], "selected"))
                q["duplicate_agreement_pct"] = L.pct(agree, len(rows))
            else:
                q["duplicate_of_key"] = ""
                q["duplicate_agreement_pct"] = None

    qmap = {q["q_position"]: q for q in questions}

    # ---- dim_archetype -----------------------------------------------------
    personas, aats = [], []
    for r in rows:
        age_exact, band, imputed = L.parse_age(r.get("archetype_age_range"))
        lo, hi, flags = L.parse_income(r.get("archetype_income_range"))
        p = {c: (r.get(c) or "").strip() for c in attr_cols}
        p.update(dict(
            wave=WAVE, panel=panel, cohort=cohort, source_file=src,
            gender_norm=L.norm_gender(r.get("archetype_gender")),
            age_exact=age_exact, age_band=band, age_band_is_imputed=int(bool(imputed)),
            income_low_usd=lo, income_high_usd=hi, income_flags="|".join(flags),
            nps_score_num=L.to_int(r.get("archetype_nps_score")),
            group_code=(r.get("group_name") or "").strip(),
        ))
        personas.append(p)

        # ---- dim_aat --------------------------------------------------------
        a = dict(archetype_id=r["archetype_id"], panel=panel, wave=WAVE)
        for c in aat_cols:
            a[c] = (r.get(c) or "").strip()
        for c in AAT_NUMERIC:
            if c in a:
                a[f"{c}_num"] = L.to_int(a[c])
        for c, order in AAT_BANDS.items():
            if c in a:
                key = {L.norm_text(v): i + 1 for i, v in enumerate(order)}
                a[f"{c}_rank"] = key.get(L.norm_text(a[c]))
        # 'High|Will use pester power to demand tickets' -> band + rationale
        rec = a.get("aat_playability_recommend", "")
        parts = [x.strip() for x in re.split(r"[|]|\s[-–—]\s", rec, maxsplit=1)]
        a["playability_recommend_band"] = parts[0] if parts and parts[0] in ("Low", "Med", "High") else None
        a["playability_recommend_note"] = parts[1] if len(parts) > 1 else ""
        blob = a.get("aat_diagnostics_json", "")
        if blob:
            try:
                a.update(flatten_json(json.loads(blob)))
                a["diagnostics_json_parsed"] = 1
            except json.JSONDecodeError:
                a["diagnostics_json_parsed"] = 0
        aats.append(a)

    # ---- facts --------------------------------------------------------------
    facts, fact_opts, options = [], [], {}
    for r in rows:
        aid = r["archetype_id"]
        for pos in positions:
            q = qmap[pos]
            sel = L.cell(r, pos, "selected")
            qual = L.cell(r, pos, "qual")
            rating = L.cell(r, pos, "rating")
            parts = L.split_multi(sel)
            codes, labels, printed = [], [], []
            for raw in parts:
                code, pr, label = L.split_option(raw)
                codes.append("" if code is None else str(code))
                labels.append(label)
                printed.append("" if pr is None else str(pr))
                key = (q["question_key"], raw)
                o = options.setdefault(key, dict(
                    question_key=q["question_key"], panel=panel, meta=q["meta"],
                    q_position=pos, option_raw=raw, option_code=code,
                    printed_scale_point=pr, option_label=label,
                    option_label_norm=L.norm_text(label), n_selected=0))
                o["n_selected"] += 1
                fact_opts.append(dict(
                    archetype_id=aid, panel=panel, question_key=q["question_key"],
                    meta=q["meta"], q_position=pos, option_raw=raw, option_code=code,
                    printed_scale_point=pr, option_label=label,
                    option_label_norm=L.norm_text(label)))
            clean, n_dir, _ = L.strip_stage_directions(qual)
            facts.append(dict(
                archetype_id=aid, panel=panel, cohort=cohort, wave=WAVE, source_file=src,
                question_key=q["question_key"], q_position=pos, meta=q["meta"],
                q_type=q["q_type"], channel=q["channel"],
                selected_raw=sel, n_selected=len(parts),
                option_codes="|".join(codes), option_labels="|".join(labels),
                printed_points="|".join(printed),
                rating_raw=rating,
                qual_raw=qual, qual_clean=clean, qual_len=len(clean),
                n_stage_directions=n_dir,
                is_harness_leak=int(L.is_harness_leak(qual)),
                answered=int(bool(sel or qual or rating))))
    return dict(panel=panel, cohort=cohort, source_file=src, n_personas=len(rows),
                n_questions=len(positions), personas=personas, aats=aats,
                questions=questions, options=list(options.values()),
                facts=facts, fact_options=fact_opts,
                attr_cols=attr_cols, aat_cols=aat_cols, header=hdr)


# --- BigQuery artefacts ------------------------------------------------------

def bq_schema(header):
    """Raw layer is 100% STRING. A silent load-time cast is unrecoverable."""
    return [{"name": bq_name(c), "type": "STRING", "mode": "NULLABLE"} for c in header]


def bq_name(col):
    n = re.sub(r"[^A-Za-z0-9_]", "_", col)
    return n if re.match(r"^[A-Za-z_]", n) else f"c_{n}"


def emit_bigquery(landed, out_dir, project="PROJECT_ID", bucket="BUCKET",
                  location="US", prefix="abr-htr/v1"):
    d = os.path.join(out_dir, "load")
    os.makedirs(d, exist_ok=True)
    slugs = {}
    for p in landed:
        slugs[p["panel"]] = f"htr_{p['panel'].lower()}"
        with open(os.path.join(d, f"schema_{p['panel'].lower()}.json"), "w") as fh:
            json.dump(bq_schema(p["header"]), fh, indent=1)

    # 1. stage to GCS under names GCS and bq can both handle (em-dash + spaces out)
    lines = ["#!/usr/bin/env bash",
             "# Stage 1: copy the three HTR exports to GCS under safe object names.",
             "# Source filenames contain an em-dash and spaces; both are hostile to",
             "# tooling that splits on whitespace. Rename on upload, never in place.",
             "set -euo pipefail",
             f'BUCKET="${{BUCKET:-gs://{bucket}}}"', f'PREFIX="{prefix}"',
             'SRC="${SRC:?set SRC to the directory holding the exports}"', ""]
    for p in landed:
        lines.append(f'gsutil cp "$SRC/{p["source_file"]}" "$BUCKET/$PREFIX/{slugs[p["panel"]]}.csv"')
    lines += ['', 'gsutil ls "$BUCKET/$PREFIX/"   # expect 3 objects', '']
    write(os.path.join(d, "01_stage_to_gcs.sh"), "\n".join(lines), 0o755)

    # 2. external tables + materialised raw (external tables are how _FILE_NAME
    #    provenance survives; a plain load loses which file a row came from)
    sql = [f"-- Stage 2: raw landing for the HTR wave ({WAVE}).",
           "-- Every column STRING. Casting happens in the curated layer where the",
           "-- rules are visible and testable.",
           "-- allow_quoted_newlines stays on: this wave has none, but the study's",
           "-- prior waves did, and the flag costs nothing.", ""]
    for p in landed:
        t = slugs[p["panel"]]
        sql += [f"CREATE OR REPLACE EXTERNAL TABLE `{project}.htr_00_raw.ext_{t}`",
                "OPTIONS (", "  format = 'CSV',",
                f"  uris = ['gs://{bucket}/{prefix}/{t}.csv'],",
                "  skip_leading_rows = 1,", "  allow_quoted_newlines = true,",
                "  ignore_unknown_values = false", ");", "",
                f"CREATE OR REPLACE TABLE `{project}.htr_00_raw.raw_{t}` AS",
                "SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at",
                f"FROM `{project}.htr_00_raw.ext_{t}`;", ""]
    write(os.path.join(d, "02_external_and_raw.sql"), "\n".join(sql))

    # 3. generated unpivot: the wide->long transform, one SELECT per question slot
    for p in landed:
        t = slugs[p["panel"]]
        sel = []
        for q in p["questions"]:
            pos = q["q_position"]
            sel.append(
                "  SELECT archetype_id, "
                f"'{p['panel']}' AS panel, '{q['question_key']}' AS question_key, "
                f"{pos} AS q_position, "
                f"Q{pos}_meta AS meta, Q{pos}_question AS question_text, Q{pos}_type AS q_type, "
                f"Q{pos}_rating AS rating_raw, Q{pos}_selected AS selected_raw, Q{pos}_qual AS qual_raw, "
                f"_source_file\n  FROM `{project}.htr_00_raw.raw_{t}`")
        body = "\n  UNION ALL\n".join(sel)
        write(os.path.join(d, f"03_unpivot_{p['panel'].lower()}.sql"),
              f"-- Generated by tools/02_land.py -- do not hand-edit.\n"
              f"-- {p['panel']}: {p['n_questions']} question slots x {p['n_personas']} personas "
              f"= {p['n_questions'] * p['n_personas']:,} fact rows.\n"
              f"CREATE OR REPLACE TABLE `{project}.htr_10_staging.stg_response_{p['panel'].lower()}`\n"
              f"CLUSTER BY meta AS\n{body};\n")

    # 4. the gate: measured targets, asserted in the warehouse
    g = [f"-- Stage 2 gate. Targets measured from the source files by tools/01_profile.py.",
         "-- Any failure here stops the build; do not proceed to the curated layer.", ""]
    for p in landed:
        g += [f"ASSERT (SELECT COUNT(*) FROM `{project}.htr_00_raw.raw_{slugs[p['panel']]}`) "
              f"= {p['n_personas']} AS '{p['panel']} raw row count != {p['n_personas']}';",
              f"ASSERT (SELECT COUNT(*) FROM `{project}.htr_10_staging.stg_response_{p['panel'].lower()}`) "
              f"= {p['n_personas'] * p['n_questions']} AS "
              f"'{p['panel']} fact rows != {p['n_personas'] * p['n_questions']}';",
              f"ASSERT (SELECT COUNT(DISTINCT archetype_id) FROM `{project}.htr_00_raw.raw_{slugs[p['panel']]}`) "
              f"= {p['n_personas']} AS '{p['panel']} archetype_id is not unique';", ""]
    write(os.path.join(d, "04_gate.sql"), "\n".join(g))

    # 5. one script to create the datasets in one region
    write(os.path.join(d, "00_datasets.sh"), "\n".join([
        "#!/usr/bin/env bash",
        "# Datasets, one region. Region mismatch between datasets, connection and",
        "# models is the commonest cause of a confusing AI.* failure later.",
        "set -euo pipefail",
        f'PROJECT="${{PROJECT:-{project}}}"', f'LOCATION="${{LOCATION:-{location}}}"',
        "for ds in htr_00_raw htr_10_staging htr_20_curated htr_30_marts htr_40_semantic; do",
        '  bq --location="$LOCATION" mk -f -d --description "ABR-HTR $ds" "$PROJECT:$ds"',
        "done", ""]), 0o755)
    return d


def write(path, text, mode=None):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text if text.endswith("\n") else text + "\n")
    if mode:
        os.chmod(path, mode)


def union_fields(dicts):
    """Stable union of keys across heterogeneous panels (aat JSON keys differ)."""
    seen = []
    for d in dicts:
        for k in d:
            if k not in seen:
                seen.append(k)
    return seen


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="out")
    ap.add_argument("--project", default="PROJECT_ID")
    ap.add_argument("--bucket", default="BUCKET")
    ap.add_argument("--location", default="US")
    a = ap.parse_args()

    landed = []
    for panel, cohort, fname in PANEL_FILES:
        path = os.path.join(a.data, fname)
        if not os.path.exists(path):
            L.die(f"missing export: {path}")
        landed.append(land_panel(path, panel, cohort))

    d = os.path.join(a.out, "landed")
    os.makedirs(d, exist_ok=True)
    tables = {
        "dim_archetype": [x for p in landed for x in p["personas"]],
        "dim_aat": [x for p in landed for x in p["aats"]],
        "dim_question": [x for p in landed for x in p["questions"]],
        "dim_question_option": [x for p in landed for x in p["options"]],
        "fct_response": [x for p in landed for x in p["facts"]],
        "fct_response_option": [x for p in landed for x in p["fact_options"]],
    }
    print(L.banner("ABR-HTR stage 2 -- land"))
    for name, rows in tables.items():
        L.write_csv(os.path.join(d, f"{name}.csv"), union_fields(rows), rows)
        print(f"  {name:<22} {len(rows):>7,} rows -> {d}/{name}.csv")

    load_dir = emit_bigquery(landed, a.out, a.project, a.bucket, a.location)
    print(f"  BigQuery artefacts     -> {load_dir}/ "
          f"({len(os.listdir(load_dir))} files: schemas, staging, external tables, unpivot, gate)")

    # ---- reconcile against stage 1 -----------------------------------------
    mpath = os.path.join(a.out, "manifest.json")
    problems = []
    if os.path.exists(mpath):
        m = json.load(open(mpath))
        tgt = {p["panel"]: p for p in m["panels"]}
        for p in landed:
            t = tgt.get(p["panel"])
            if not t:
                problems.append(f"{p['panel']}: absent from manifest")
                continue
            got_facts = len(p["facts"])
            if got_facts != t["expected_fact_rows"]:
                problems.append(f"{p['panel']}: {got_facts:,} fact rows, expected {t['expected_fact_rows']:,}")
            if len(p["personas"]) != t["n_personas"]:
                problems.append(f"{p['panel']}: {len(p['personas'])} personas, expected {t['n_personas']}")
    else:
        problems.append("out/manifest.json not found -- run tools/01_profile.py first")

    ids = [r["archetype_id"] for r in tables["dim_archetype"]]
    if len(set(ids)) != len(ids):
        problems.append(f"dim_archetype: {len(ids) - len(set(ids))} duplicate archetype_id")
    keys = {q["question_key"] for q in tables["dim_question"]}
    if len(keys) != len(tables["dim_question"]):
        problems.append("dim_question: question_key collision -- (panel, meta, text) is not unique")
    orphan = {f["question_key"] for f in tables["fct_response"]} - keys
    if orphan:
        problems.append(f"fct_response: {len(orphan)} question_key values with no dim row")

    print(f"\n  reconciliation: {'OK' if not problems else str(len(problems)) + ' PROBLEM(S)'}")
    for p in problems:
        print(f"    FAIL {p}")
    answered = sum(f["answered"] for f in tables["fct_response"])
    print(f"  facts answered: {answered:,}/{len(tables['fct_response']):,} "
          f"({L.pct(answered, len(tables['fct_response']))}%)")
    print(f"  verbatims with stage directions: "
          f"{sum(1 for f in tables['fct_response'] if f['n_stage_directions']):,}")
    print(f"  harness-leak cells quarantined: "
          f"{sum(f['is_harness_leak'] for f in tables['fct_response'])}")
    raise SystemExit(1 if problems else 0)


if __name__ == "__main__":
    main()
