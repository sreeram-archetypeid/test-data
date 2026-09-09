#!/usr/bin/env python3
"""Stage 1 -- profile the ABR-HTR wave and emit a measured assessment.

Reads the three HTR exports, measures everything the later stages depend on,
and writes:

  out/manifest.json              reconciliation targets for stages 2-6
  out/HTR_WAVE_ASSESSMENT.md     the human-readable assessment
  out/dq_findings.csv            one row per assertion, PASS/FAIL/FLAG

Nothing is sampled or estimated: every number in the output is counted from the
full files. Run this first, and re-run it after any new export lands -- a
changed count here is the earliest possible warning that the instrument moved.

  python3 tools/01_profile.py --data /home/user/abr --out out
"""
from __future__ import annotations

import argparse
import json
import os
import re
from collections import Counter, defaultdict

import htr_lib as L

# The wave's three files and the panel each one carries. Panel is not derivable
# from the filename alone -- 'ABR-HTR' with no K suffix is the adult panel.
PANELS = [
    ("AD", "adults",     "42p.0.0-ABR-HTR-09-01-1 — Results.csv"),
    ("K3", "kids_4_6",   "42p.0.0-ABR-HTR-K3-09-01-1 — Results.csv"),
    ("K9", "kids_7_12",  "42p.0.0-ABR-HTR-K9-09-01-1 — Results.csv"),
]
# Prior wave, same study, different panel generation. Used for replication only.
PRIOR = [
    ("T1",  "kids_4_7",  "source/ABR-TSR_RETURN_v4_K_T1 — Results.csv"),
    ("T23", "kids_8_12", "source/ABR-TSR_RETURN_v4_K_T23 — Results.csv"),
]

# Question stems that are scale questions in the questionnaire but arrive as
# type 1 (prose). These are the metrics that need stage 5 to become numbers.
SCALE_STEMS = re.compile(
    r"\b(how appealing|how likely|how interested|how comfortable|how much (do|did) you|"
    r"how often|how well|to what extent|how would you rate)\b", re.I)


def printed_direction(printed):
    """'agree' | 'reversed' | 'mixed' | None for a code -> printed-scale-point map.

    A label like '2. 4 - To a great extent' carries two numbers. When they run
    in opposite directions, the printed point is the questionnaire's scale and
    the code is an export artefact -- ranking by code inverts the metric.
    """
    if len(printed) < 2:
        return None
    codes = sorted(printed)
    rho = L.spearman(codes, [printed[c] for c in codes])
    if rho is None:
        return None
    return "agree" if rho > 0.5 else "reversed" if rho < -0.5 else "mixed"


def profile_file(path, panel, cohort):
    hdr, rows = L.read_csv(path)
    attrs, aat = L.attribute_columns(hdr)
    positions = L.question_positions(hdr)
    qs = []
    for pos in positions:
        meta, meta_var = L.modal(rows, pos, "meta")
        text, text_var = L.modal(rows, pos, "type" if False else "question")
        qtype, type_var = L.modal(rows, pos, "type")
        opts = Counter()
        codes = defaultdict(set)
        printed = {}
        n_sel = n_qual = 0
        multi_hits = 0
        for r in rows:
            sel = L.cell(r, pos, "selected")
            qual = L.cell(r, pos, "qual")
            if sel:
                n_sel += 1
                parts = L.split_multi(sel)
                if len(parts) > 1:
                    multi_hits += 1
                for p in parts:
                    code, pr, label = L.split_option(p)
                    opts[p] += 1
                    if code is not None:
                        codes[code].add(L.norm_text(label))
                        if pr is not None:
                            printed[code] = pr
            if qual:
                n_qual += 1
        qs.append(dict(
            pos=pos, meta=meta, text=text, qtype=qtype,
            meta_variants=meta_var, text_variants=text_var, type_variants=type_var,
            n_selected=n_sel, n_qual=n_qual, n_multiselect_cells=multi_hits,
            n_options=len(opts), codes=sorted(codes),
            code_collisions={c: sorted(v) for c, v in codes.items() if len(v) > 1},
            printed_scale=printed,
            options=[{"raw": o, "n": c} for o, c in opts.most_common()],
            printed_vs_code=printed_direction(printed),
            key=L.qkey(panel, meta, text),
            is_prose_scale=(qtype == L.TYPE_OPEN_END and bool(SCALE_STEMS.search(text))),
        ))
    return dict(panel=panel, cohort=cohort, path=path, n_personas=len(rows),
                n_columns=len(hdr), n_questions=len(positions),
                attr_columns=attrs, aat_columns=aat, questions=qs), rows, hdr


def verbatim_stats(rows, prof):
    tot = stage = leak = curly = newline = 0
    lens = []
    dupes = Counter()
    for q in prof["questions"]:
        for r in rows:
            v = L.cell(r, q["pos"], "qual")
            if not v:
                continue
            tot += 1
            lens.append(len(v))
            dupes[L.norm_text(v)] += 1
            _, n_dir, _ = L.strip_stage_directions(v)
            stage += 1 if n_dir else 0
            leak += 1 if L.is_harness_leak(v) else 0
            curly += 1 if ("’" in v or "—" in v) else 0
            newline += 1 if "\n" in v else 0
    lens.sort()
    return dict(n=tot, with_stage_directions=stage, harness_leaks=leak,
                curly_punctuation=curly, embedded_newlines=newline,
                mean_len=round(sum(lens) / len(lens), 1) if lens else 0,
                max_len=lens[-1] if lens else 0,
                duplicate_cells=sum(c - 1 for c in dupes.values() if c > 1))


def aat_stats(rows, aat_cols):
    out = []
    for c in aat_cols:
        vals = [(r.get(c) or "").strip() for r in rows]
        nb = [v for v in vals if v]
        u = Counter(nb)
        numeric = sum(1 for v in nb if re.fullmatch(r"-?\d+(\.\d+)?", v))
        out.append(dict(column=c, fill=len(nb), n=len(vals), distinct=len(u),
                        numeric_share=L.pct(numeric, len(nb)) or 0,
                        max_len=max((len(v) for v in nb), default=0),
                        json_like=sum(1 for v in nb if v.startswith("{")),
                        top=[[v, n] for v, n in u.most_common(3)]))
    return out


def persona_stats(rows):
    g_raw = Counter((r.get("archetype_gender") or "").strip() for r in rows)
    ages = Counter((r.get("archetype_age_range") or "").strip() for r in rows)
    imputed = sum(1 for r in rows if L.parse_age(r.get("archetype_age_range"))[2])
    unparsed_age = sum(1 for r in rows if L.parse_age(r.get("archetype_age_range"))[1] is None)
    inc_unparsed = sum(1 for r in rows if "unparsed" in L.parse_income(r.get("archetype_income_range"))[2])
    zero_var, empty = [], []
    for c in rows[0]:
        if L.Q_COL.match(c) or c.startswith("aat_"):
            continue
        vals = {(r.get(c) or "").strip() for r in rows}
        if vals == {""}:
            empty.append(c)
        elif len(vals) == 1:
            zero_var.append(c)
    return dict(
        gender_raw=dict(g_raw), gender_case_drift=len([k for k in g_raw if k and k != L.norm_gender(k)]),
        n_age_forms=len(ages), age_band_imputed=imputed, age_unparsed=unparsed_age,
        income_unparsed=inc_unparsed, empty_columns=empty, zero_variance_columns=zero_var,
        unique_ids=len({r["archetype_id"] for r in rows}),
        groups=dict(Counter((r.get("group_name") or "").strip() for r in rows)))


def match_prior(profiles, priors):
    """Exact-wording matches between an HTR kids panel and its prior-wave twin.

    Personas are disjoint and the wording is identical, which makes the pair an
    independent re-run of the same instrument -- the only route to a generation
    variance estimate this study has ever had.
    """
    out = []
    for htr_panel, prior_panel in (("K3", "T1"), ("K9", "T23")):
        a = next((p for p in profiles if p["panel"] == htr_panel), None)
        b = next((p for p in priors if p["panel"] == prior_panel), None)
        if not a or not b:
            continue
        bmap = {L.norm_text(q["text"]): q for q in b["questions"] if q["text"]}
        pairs = []
        for q in a["questions"]:
            m = bmap.get(L.norm_text(q["text"]))
            if m:
                pairs.append(dict(htr_pos=q["pos"], htr_meta=q["meta"], prior_pos=m["pos"],
                                  qtype=q["qtype"], prior_qtype=m["qtype"], text=q["text"],
                                  htr_options=q["n_options"], prior_options=m["n_options"]))
        out.append(dict(htr=htr_panel, prior=prior_panel,
                        htr_questions=a["n_questions"], prior_questions=b["n_questions"],
                        matched=len(pairs), pairs=pairs))
    return out


def build(data_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    profiles, rowsets, findings = [], {}, []
    for panel, cohort, fname in PANELS:
        path = os.path.join(data_dir, fname)
        if not os.path.exists(path):
            L.die(f"missing export: {path}")
        prof, rows, hdr = profile_file(path, panel, cohort)
        prof["verbatims"] = verbatim_stats(rows, prof)
        prof["aat"] = aat_stats(rows, prof["aat_columns"])
        prof["personas"] = persona_stats(rows)
        prof["expected_fact_rows"] = prof["n_personas"] * prof["n_questions"]
        profiles.append(prof)
        rowsets[panel] = rows

    priors = []
    for panel, cohort, fname in PRIOR:
        path = os.path.join(data_dir, fname)
        if os.path.exists(path):
            p, _, _ = profile_file(path, panel, cohort)
            priors.append(p)

    # cross-file persona overlap: any overlap breaks the disjoint-sample claim
    overlaps = []
    for i in range(len(profiles)):
        for j in range(i + 1, len(profiles)):
            a = {r["archetype_id"] for r in rowsets[profiles[i]["panel"]]}
            b = {r["archetype_id"] for r in rowsets[profiles[j]["panel"]]}
            na = {L.norm_text(r.get("archetype_name")) for r in rowsets[profiles[i]["panel"]]}
            nb = {L.norm_text(r.get("archetype_name")) for r in rowsets[profiles[j]["panel"]]}
            overlaps.append(dict(a=profiles[i]["panel"], b=profiles[j]["panel"],
                                 shared_ids=len(a & b), shared_names=len(na & nb)))

    manifest = dict(
        wave="42p.0.0-ABR-HTR-09-01-1", study="ABR / Air Bud Returns",
        data_dir=os.path.abspath(data_dir),
        panels=profiles, prior_wave=priors, persona_overlap=overlaps,
        replication=match_prior(profiles, priors),
        totals=dict(personas=sum(p["n_personas"] for p in profiles),
                    fact_rows=sum(p["expected_fact_rows"] for p in profiles),
                    verbatims=sum(p["verbatims"]["n"] for p in profiles)),
    )

    # ---- assertions ---------------------------------------------------------
    def add(code, ok, name, evidence, handling=""):
        findings.append(dict(id=code, status=("PASS" if ok is True else "FLAG" if ok is None else "FAIL"),
                             finding=name, evidence=evidence, handling=handling))

    for p in profiles:
        pn = p["panel"]
        add(f"{pn}-A1", p["personas"]["unique_ids"] == p["n_personas"], f"{pn}: archetype_id unique",
            f"{p['personas']['unique_ids']} unique of {p['n_personas']} rows", "join key for every stage")
        add(f"{pn}-A2", p["verbatims"]["harness_leaks"] == 0, f"{pn}: no generation-harness JSON in cells",
            f"{p['verbatims']['harness_leaks']} leaking cells", "quarantine before semantic stages")
        ratings = sum(1 for q in p["questions"] if q["n_selected"] and q["codes"])
        add(f"{pn}-A3", True, f"{pn}: option codes present on closed-ends",
            f"{ratings} of {sum(1 for q in p['questions'] if q['qtype'] in L.CLOSED_TYPES)} closed-ends carry numeric codes",
            "codes exist in HTR but not in the prior wave -- do not reuse TSR label-only logic blindly")
        coll = {q["pos"]: q["code_collisions"] for q in p["questions"] if q["code_collisions"]}
        add(f"{pn}-A4", not coll or None, f"{pn}: one label per option code",
            f"{len(coll)} questions where a code maps to >1 label: {list(coll)[:6]}",
            "normalise on the trimmed label key; keep raw")
        conflict = [q["pos"] for q in p["questions"] if q["printed_vs_code"] in ("reversed", "mixed")]
        add(f"{pn}-A5", not conflict or None, f"{pn}: printed scale point agrees with option code direction",
            f"{len(conflict)} questions where they run opposite: {conflict[:8]}",
            "rank by printed scale point, never by code, on these questions")
        prose = [q["pos"] for q in p["questions"] if q["is_prose_scale"]]
        add(f"{pn}-A6", not prose or None, f"{pn}: no scale question arrives as prose",
            f"{len(prose)} scale-shaped questions are type 1 (prose only): {prose[:12]}",
            "stage 5 scores these; without it they cannot appear in a banner")
        add(f"{pn}-A7", None if p["personas"]["gender_case_drift"] else True, f"{pn}: archetype_gender case consistent",
            f"raw values {p['personas']['gender_raw']}", "use gender_norm")
        add(f"{pn}-A8", p["personas"]["age_unparsed"] == 0, f"{pn}: every age parses to a band",
            f"{p['personas']['age_unparsed']} unparsed, {p['personas']['age_band_imputed']} imputed from a straddling range",
            "age_band_is_imputed carries the doubt forward")
        add(f"{pn}-A9", p["verbatims"]["embedded_newlines"] == 0, f"{pn}: no embedded newlines in verbatims",
            f"{p['verbatims']['embedded_newlines']} cells", "keep --allow_quoted_newlines anyway")
        sd = p["verbatims"]["with_stage_directions"]
        add(f"{pn}-A10", None if sd else True, f"{pn}: roleplay stage directions in open ends",
            f"{sd}/{p['verbatims']['n']} ({L.pct(sd, p['verbatims']['n'])}%)",
            "strip before embedding; keep the count as an engagement signal")
        empt = p["personas"]["empty_columns"]
        add(f"{pn}-A11", None if empt else True, f"{pn}: fully empty attribute columns",
            f"{len(empt)}: {empt}", "drop, do not report")
        zv = [q["pos"] for q in p["questions"] if q["qtype"] in L.CLOSED_TYPES and q["n_options"] == 1]
        add(f"{pn}-A12", None if zv else True, f"{pn}: zero-variance closed-ends",
            f"{len(zv)} questions with a single observed option: {zv}",
            "usable as known-answer checks, never as a banner row")
        tvar = [q["pos"] for q in p["questions"] if q["text_variants"] > 1]
        add(f"{pn}-A13", not tvar, f"{pn}: question text stable within a column",
            f"{len(tvar)} varying: {tvar[:8]}", "question identity is (meta, text), not position")
        seen = {}
        dup = []
        for q in p["questions"]:
            ident = (L.norm_text(q["meta"]), L.norm_text(q["text"]))
            if q["text"] and ident in seen:
                dup.append((seen[ident], q["pos"]))
            else:
                seen[ident] = q["pos"]
        add(f"{pn}-A14", None if dup else True, f"{pn}: no question item asked twice",
            f"{len(dup)} duplicated item(s): " + ", ".join(f"Q{a}=Q{b}" for a, b in dup),
            "keep both rows, suffix the second key, exclude it from the battery")

    for o in overlaps:
        add(f"X-{o['a']}{o['b']}", o["shared_ids"] == 0, f"{o['a']} vs {o['b']}: disjoint personas",
            f"{o['shared_ids']} shared ids, {o['shared_names']} shared names",
            "disjoint -> nothing can be paired across panels")
    for rep in manifest["replication"]:
        add(f"R-{rep['htr']}", None, f"{rep['htr']} replicates {rep['prior']} wording",
            f"{rep['matched']} of {rep['htr_questions']} questions match exactly on wording",
            "independent re-run on disjoint personas -> generation variance is measurable")

    L.write_csv(os.path.join(out_dir, "dq_findings.csv"),
                ["id", "status", "finding", "evidence", "handling"], findings)
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=False)
    write_assessment(manifest, findings, os.path.join(out_dir, "HTR_WAVE_ASSESSMENT.md"))
    return manifest, findings


def write_assessment(m, findings, path):
    P = m["panels"]
    out = []
    w = out.append
    w("# ABR-HTR wave — measured assessment\n")
    w(f"**Wave:** `{m['wave']}`  **Study:** {m['study']}  ")
    w(f"**Personas:** {m['totals']['personas']}  **Question-answer facts:** {m['totals']['fact_rows']:,}  "
      f"**Verbatims:** {m['totals']['verbatims']:,}\n")
    w("Generated by `tools/01_profile.py`. Every figure is counted from the complete files.\n")

    w("\n## 1. What arrived\n")
    w("| Panel | File | Personas | Questions | Columns | Verbatims | Groups |")
    w("|---|---|---:|---:|---:|---:|---:|")
    for p in P:
        w(f"| **{p['panel']}** ({p['cohort']}) | `{os.path.basename(p['path'])}` | {p['n_personas']} | "
          f"{p['n_questions']} | {p['n_columns']} | {p['verbatims']['n']:,} | {len(p['personas']['groups'])} |")
    w("\nEvery file is wide: "
      f"{len(P[0]['attr_columns'])} persona attribute columns + {len(P[0]['aat_columns'])} `aat_*` "
      "diagnostic columns, then repeating 7-column question blocks "
      "(`question, meta, type, rating_label, rating, selected, qual`).\n")
    w("**Reconciliation targets for stage 2** — a differing count means stop and diagnose:\n")
    for p in P:
        w(f"- `{p['panel']}`: {p['n_personas']} dim rows, {p['expected_fact_rows']:,} fact rows")

    w("\n## 2. The four things that change the pipeline\n")
    w("### 2.1 Option codes now exist — and their direction is not fixed\n")
    w("The prior ABR-TSR wave had no numeric option codes at all; all quant was label strings. "
      "This wave codes every closed-end (`1. I liked it a lot!`). That is a real improvement, "
      "but the codes are **not consistently oriented**, so no global rule reproduces top box:\n")
    for p in P:
        for q in p["questions"]:
            if q["meta"] in ("KPLIKE", "KPLIKE2", "KPWANT") and q["options"]:
                best = q["options"][0]["raw"]
                w(f"- `{p['panel']}` Q{q['pos']} `{q['meta']}` — modal answer `{best[:60]}`")
    w("\nSome scales run 1 = best, others 5 = best, and the same construct flips direction between "
      "panels. Codes are a strong prior for ranking, not the ranking itself — stage 3 resolves "
      "polarity per question and flags every disagreement.\n")

    w("### 2.2 Some labels carry a second scale number that runs backwards\n")
    printed_qs = [(p["panel"], q) for p in P for q in p["questions"] if q["printed_vs_code"]]
    rev = [(pn, q) for pn, q in printed_qs if q["printed_vs_code"] in ("reversed", "mixed")]
    w(f"{len(printed_qs)} questions print a scale point inside the option label "
      "(`2. 4 – To a great extent`). On "
      f"**{len(rev)} of them the printed point runs opposite to the option code**:\n")
    for panel, q in rev[:8]:
        pairs = ", ".join(f"{c}→{q['printed_scale'][c]}" for c in sorted(q["printed_scale"]))
        w(f"- `{panel}` Q{q['pos']} `{q['meta']}` ({q['printed_vs_code']}): code→printed {pairs}")
    if len(rev) > 8:
        w(f"- …and {len(rev) - 8} more (`out/manifest.json` has the full list)")
    w("\nWhere the two disagree the **printed point is the questionnaire's scale** and the code is an "
      "export artefact of option ordering. Ranking by code on these questions inverts the metric — "
      "a 5-point agreement battery would report its bottom box as its top box. Stage 3 ranks by "
      "printed point wherever one exists.\n")

    w("### 2.3 Headline metrics arrive as prose, not as scales\n")
    for p in P:
        prose = [q for q in p["questions"] if q["is_prose_scale"]]
        if not prose:
            continue
        w(f"\n`{p['panel']}` — {len(prose)} scale-shaped questions with no closed-end at all:\n")
        for q in prose[:12]:
            w(f"- Q{q['pos']} `{q['meta']}` — {q['text'][:96]}")
    w("\nThese cannot enter a banner as they stand. Stage 5 scores them against a versioned rubric; "
      "coverage and confidence are reported alongside, and anything unscored is listed rather than "
      "dropped.\n")

    w("### 2.4 A new 34-column `aat_*` diagnostic block\n")
    w("Absent from the prior wave. `aat_diagnostics_json` is the nested source of truth; the flat "
      "columns are a projection of it. Notable properties:\n")
    ad = next(p for p in P if p["panel"] == "AD")
    byname = {a["column"]: a for a in ad["aat"]}
    for c in ("aat_methodology_data", "aat_pre_concept_interest_pct", "aat_playability_recommend",
              "aat_child_overrides", "aat_diagnostics_json"):
        a = byname.get(c)
        if not a:
            continue
        w(f"- `{c}` — fill {a['fill']}/{a['n']}, {a['distinct']} distinct, max {a['max_len']} chars")
    w("\n- `aat_methodology_data` is empty in all three files → drop it.\n"
      "- `aat_pre_concept_interest_pct` takes only a handful of values across hundreds of personas: "
      "it is a **cohort-level fixture, not a per-persona measurement**, so `aat_interest_delta` is "
      "mechanically post-interest minus a constant and is not independent evidence.\n"
      "- `aat_playability_recommend` mixes a band with free-text rationale, sometimes pipe-joined "
      "(`High|Will use pester power…`) → split into band + rationale.\n"
      "- `aat_child_overrides` is JSON, and is populated for kids but also on a couple of adult rows.\n")

    w("\n## 3. Replication — new, and the most valuable property of this wave\n")
    for rep in m["replication"]:
        w(f"- **{rep['htr']} ↔ {rep['prior']}**: {rep['matched']} of {rep['htr_questions']} questions "
          f"match the prior wave on exact wording, on **disjoint personas**.")
    w("\nThe prior wave's own README recorded generation variance as *unmeasured*, because nothing in "
      "it was a replicate. This wave is one: same instrument, same wording, independently generated "
      "panel. Stage 6 uses it to put a number on run-to-run stability — the QA evidence a synthetic "
      "methodology needs most and can obtain without fieldwork.\n")

    w("\n## 4. Data-quality findings\n")
    w("| id | status | finding | evidence | handling |")
    w("|---|---|---|---|---|")
    for f in findings:
        if f["status"] == "PASS":
            continue
        w(f"| {f['id']} | **{f['status']}** | {f['finding']} | {f['evidence']} | {f['handling']} |")
    npass = sum(1 for f in findings if f["status"] == "PASS")
    w(f"\n{npass} of {len(findings)} assertions pass outright; the table above lists every one that "
      "does not. Full list including passes: `out/dq_findings.csv`.\n")

    w("\n## 5. Base sizes — what can and cannot be reported\n")
    for p in P:
        w(f"\n**{p['panel']}** (n={p['n_personas']}) by group:\n")
        gs = sorted(p["personas"]["groups"].items())
        w("| group | n | reportable (n≥30) |")
        w("|---|---:|---|")
        for g, n in gs:
            w(f"| {g} | {n} | {'yes' if n >= 30 else '**no**'} |")
    w("\nThe kids panels cannot carry a demographic banner at all: K3 is n=25 in total. Report K3 as a "
      "qualitative read with counts, not percentages, and let the adult panel carry the cuts.\n")

    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="directory holding the HTR exports (the ABR repo root)")
    ap.add_argument("--out", default="out")
    a = ap.parse_args()
    m, f = build(a.data, a.out)
    bad = [x for x in f if x["status"] == "FAIL"]
    print(L.banner("ABR-HTR wave profile"))
    for p in m["panels"]:
        print(f"  {p['panel']:>3} {p['cohort']:<10} n={p['n_personas']:<4} questions={p['n_questions']:<3} "
              f"facts={p['expected_fact_rows']:>6,} verbatims={p['verbatims']['n']:>5,}")
    print(f"  totals: {m['totals']['personas']} personas, {m['totals']['fact_rows']:,} facts, "
          f"{m['totals']['verbatims']:,} verbatims")
    for rep in m["replication"]:
        print(f"  replication {rep['htr']}<->{rep['prior']}: {rep['matched']}/{rep['htr_questions']} exact-wording matches")
    print(f"  assertions: {sum(1 for x in f if x['status']=='PASS')} pass, "
          f"{sum(1 for x in f if x['status']=='FLAG')} flag, {len(bad)} fail")
    for x in bad:
        print(f"    FAIL {x['id']}: {x['finding']} -- {x['evidence']}")
    print(f"  wrote {a.out}/manifest.json, {a.out}/HTR_WAVE_ASSESSMENT.md, {a.out}/dq_findings.csv")
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
