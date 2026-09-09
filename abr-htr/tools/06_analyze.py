#!/usr/bin/env python3
"""Stage 6 -- the analysis: banner, equated cross-panel read, replication, drivers.

Five things, in the order they should be trusted:

  1. Banner. Base, top box, top-2 box, bottom box and latent mean for every
     ordinal favourability question, by cut, each with a Wilson interval and a
     base-size flag. Nominal questions are reported as option shares instead --
     forcing a rank onto "who would you watch with" invents a scale the
     questionnaire never asked for.

  2. Equated cross-panel read. K3 asks 3-point scales where K9 asks 5-point ones
     for the same construct, so raw top box cannot cross them. Both raw and
     equated numbers are printed side by side, because the gap between them is
     the finding: it is the difference between an instrument artefact and a real
     age effect.

  3. Replication against the prior wave. 39 of K9's 40 questions and 31 of K3's
     36 are worded identically to ABR-TSR's T23 and T1, on disjoint personas.
     That makes run-to-run variance measurable for the first time in this study.
     Rank-order agreement is reported alongside level agreement, because levels
     need a human anchor and rank order does not.

  4. Known-answer accuracy. The trailer said theatrical, and it said January 22,
     2027. Recall questions are scored against those facts -- the one form of
     validation available with no human benchmark at all.

  5. Drivers. What travels with theatrical intent: latent metrics and themes,
     ranked by rank correlation, with n and an honest note on what n=273 can
     and cannot support.

  python3 tools/06_analyze.py --out out
"""
from __future__ import annotations

import argparse
import csv
import importlib
import os
import re
import sys
from collections import Counter, defaultdict

import htr_lib as L

SCALE_MAP_MODULE = "03_scale_map"

# Prior wave, for the replication test. No option codes at all in these files.
PRIOR = [("K3", "T1", "source/ABR-TSR_RETURN_v4_K_T1 — Results.csv"),
         ("K9", "T23", "source/ABR-TSR_RETURN_v4_K_T23 — Results.csv")]

# What the trailer actually said. Sourced from the export's own modal answers and
# from the release-date text personas quote verbatim; both are checkable facts,
# not opinions, which is what makes them scoreable.
KNOWN_ANSWERS = [
    ("DLOC", r"movie theat(re|er)|in theat(re|er)s", "availability: in movie theatres"),
    ("KPRSE", r"movie theat(re|er)", "availability: in movie theatres"),
    ("RETITLE", r"air bud returns", "title: Air Bud Returns"),
    ("DRELEASE", r"january\s*22,?\s*2027|january\s*2027", "release: January 22, 2027"),
]


def read(path):
    return list(csv.DictReader(open(path, encoding="utf-8")))


def pct_or_dash(v):
    """A 2-point scale has no top-2 box; print a dash rather than a fake zero."""
    return f"{v:.1f}%" if isinstance(v, (int, float)) else "-"


def load_scale_module():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    return importlib.import_module(SCALE_MAP_MODULE)


# --- 1. banner ---------------------------------------------------------------

def build_banner(landed, out_dir, min_base):
    personas = {p["archetype_id"]: p for p in read(os.path.join(landed, "dim_archetype.csv"))}
    questions = {q["question_key"]: q for q in read(os.path.join(landed, "dim_question.csv"))}
    decisions = {d["question_key"]: d for d in read(os.path.join(out_dir, "scale_map_questions.csv"))}
    smap = {}
    for o in read(os.path.join(out_dir, "scale_map.csv")):
        smap[(o["question_key"], o["option_raw"])] = o

    rows, shares = [], []
    acc, nom = {}, {}
    for f in read(os.path.join(landed, "fct_response_option.csv")):
        qk = f["question_key"]
        d = decisions.get(qk)
        p = personas.get(f["archetype_id"])
        if not d or not p:
            continue
        o = smap.get((qk, f["option_raw"]))
        if not o:
            continue
        for cut, val in L.banner_cuts(p):
            if d["is_ordinal"] == "1" and d["scale_role"] == "favourability":
                b = acc.setdefault((qk, cut, val), dict(
                    base=set(), tb=0, t2b=0, bb=0, b2b=0, eqtb=0, latent=[], sentinel=0))
                if o["is_sentinel"] == "1":
                    b["sentinel"] += 1
                    continue                       # excluded from every box and the mean
                b["base"].add(f["archetype_id"])
                b["tb"] += int(o["is_top_box"] == "1")
                b["t2b"] += int(o["is_top2_box"] == "1")
                b["bb"] += int(o["is_bottom_box"] == "1")
                b["b2b"] += int(o["is_bottom2_box"] == "1")
                b["eqtb"] += int(o["is_equated_top_box"] == "1")
                if o["latent_favourability"]:
                    b["latent"].append(float(o["latent_favourability"]))
            else:
                s = nom.setdefault((qk, cut, val), dict(base=set(), counts=Counter()))
                s["base"].add(f["archetype_id"])
                s["counts"][o["option_label"] or o["option_raw"]] += 1

    for (qk, cut, val), b in sorted(acc.items()):
        d, q = decisions[qk], questions[qk]
        n = len(b["base"])
        if not n:
            continue
        lo, hi = L.wilson(b["tb"], n)
        lo2, hi2 = L.wilson(b["t2b"], n)
        # A 2-point scale has no top-2 box. Reporting 0.0% there reads as a
        # measured zero, which is worse than reporting nothing.
        two_box = int(d["scale_max"] or 0) >= 3
        rows.append(dict(
            panel=d["panel"], meta=d["meta"], q_position=d["q_position"],
            question_text=q["question_text"][:110], construct_polarity=d["construct_polarity"],
            rank_basis=d["rank_basis"], scale_points=d["scale_max"],
            cut=cut, cut_value=val, base=n, sentinel_excluded=b["sentinel"],
            top_box_pct=L.pct(b["tb"], n), tb_ci_low=round(100 * lo, 1), tb_ci_high=round(100 * hi, 1),
            top2_box_pct=L.pct(b["t2b"], n) if two_box else None,
            t2b_ci_low=round(100 * lo2, 1) if two_box else None,
            t2b_ci_high=round(100 * hi2, 1) if two_box else None,
            bottom_box_pct=L.pct(b["bb"], n),
            bottom2_box_pct=L.pct(b["b2b"], n) if two_box else None,
            equated_top_box_pct=L.pct(b["eqtb"], n),
            latent_mean=round(sum(b["latent"]) / len(b["latent"]), 1) if b["latent"] else None,
            base_flag="" if n >= min_base else f"BASE<{min_base} -- counts only"))
    for (qk, cut, val), s in sorted(nom.items()):
        d, q = decisions[qk], questions[qk]
        n = len(s["base"])
        for label, k in s["counts"].most_common():
            lo, hi = L.wilson(k, n)
            shares.append(dict(
                panel=d["panel"], meta=d["meta"], q_position=d["q_position"],
                question_text=q["question_text"][:110], rank_basis=d["rank_basis"],
                cut=cut, cut_value=val, base=n, option_label=label, n=k, pct=L.pct(k, n),
                ci_low=round(100 * lo, 1), ci_high=round(100 * hi, 1),
                base_flag="" if n >= min_base else f"BASE<{min_base} -- counts only"))
    return rows, shares


# --- 2. equated cross-panel --------------------------------------------------

def option_label_overlap(landed, out_dir):
    """Normalised option-label sets per (panel, meta), for comparability checks."""
    decisions = {d["question_key"]: d for d in read(os.path.join(out_dir, "scale_map_questions.csv"))}
    sets = {}
    for o in read(os.path.join(out_dir, "scale_map.csv")):
        d = decisions.get(o["question_key"])
        if not d or o["is_sentinel"] == "1":
            continue
        sets.setdefault((d["panel"], d["meta"]), set()).add(o["option_label_norm"])
    return sets


def cross_panel(banner_rows, label_sets=None):
    """Match K3 and K9 on question meta and show raw next to equated.

    The prior wave's assessment found a 37-54 point 'appeal collapse with age'
    that was entirely an artefact of comparing a 2-3 point scale's top box with
    a 5-point scale's top box. Print both readings so that mistake cannot be
    repeated silently.
    """
    idx = {(r["panel"], r["meta"]): r for r in banner_rows if r["cut"] == "total"}
    out = []
    for (panel, meta), r in sorted(idx.items()):
        if panel != "K3":
            continue
        other = idx.get(("K9", meta))
        if not other:
            continue
        raw_gap = (other["top_box_pct"] or 0) - (r["top_box_pct"] or 0)
        lat_gap = (other["latent_mean"] or 0) - (r["latent_mean"] or 0)
        t2b_gap = (other["top2_box_pct"] or 0) - (r["top2_box_pct"] or 0)
        overlap = None
        if label_sets:
            a3, a9 = label_sets.get(("K3", meta), set()), label_sets.get(("K9", meta), set())
            if a3 and a9:
                overlap = round(len(a3 & a9) / len(a3 | a9), 2)
        out.append(dict(
            meta=meta, question_text=r["question_text"][:80], option_label_overlap=overlap,
            k3_points=r["scale_points"], k9_points=other["scale_points"],
            k3_base=r["base"], k9_base=other["base"],
            k3_top_box=r["top_box_pct"], k9_top_box=other["top_box_pct"], raw_top_box_gap=round(raw_gap, 1),
            k3_top2=r["top2_box_pct"], k9_top2=other["top2_box_pct"], top2_gap=round(t2b_gap, 1),
            k3_latent_mean=r["latent_mean"], k9_latent_mean=other["latent_mean"],
            latent_gap=round(lat_gap, 1),
            scale_mismatch=int(r["scale_points"] != other["scale_points"]),
            verdict=(
                # Same construct, same number of points, but no shared option
                # wording is not one scale measured twice -- K3's KPUND offers
                # "Easy / Some parts were hard" where K9 offers "Very easy /
                # Mostly easy". Equating those compares two different questions.
                "different option sets -- not comparable"
                if overlap == 0.0 else
                "scale artefact -- do not report the raw gap"
                if r["scale_points"] != other["scale_points"] and abs(raw_gap) - abs(lat_gap) > 10
                else "real difference" if abs(lat_gap) >= 10 else "no material difference")))
    return out


# --- 3. replication against the prior wave -----------------------------------

def replication(data_dir, landed, out_dir, banner_rows, scale_mod, lexicon_path):
    lex = scale_mod.load_lexicon(lexicon_path)
    cur = {(r["panel"], L.norm_text(r["question_text"])): r
           for r in banner_rows if r["cut"] == "total"}
    questions = read(os.path.join(landed, "dim_question.csv"))
    text_by_key = {q["question_key"]: q for q in questions}
    out = []
    for htr_panel, prior_panel, fname in PRIOR:
        path = os.path.join(data_dir, fname)
        if not os.path.exists(path):
            continue
        hdr, rows = L.read_csv(path)
        for pos in L.question_positions(hdr):
            meta, _ = L.modal(rows, pos, "meta")
            text, _ = L.modal(rows, pos, "question")
            qtype, _ = L.modal(rows, pos, "type")
            if qtype not in L.CLOSED_TYPES or not text:
                continue
            key = (htr_panel, L.norm_text(text))
            match = cur.get(key)
            if not match or not match["latent_mean"]:
                continue
            counts = Counter()
            for r in rows:
                for part in L.split_multi(L.cell(r, pos, "selected")):
                    counts[part] += 1
            if len(counts) < 2:
                continue
            # rank the prior wave's label-only options with the same lexicon the
            # HTR wave uses, so the two are scored by one rule, not two
            fake_q = dict(question_key=f"{prior_panel}_{pos}", panel=prior_panel, meta=meta,
                          q_position=pos, q_type=qtype, channel="single_select",
                          question_text=text)
            fake_opts = []
            for raw, n in counts.items():
                code, printed, label = L.split_option(raw)
                fake_opts.append(dict(question_key=fake_q["question_key"], panel=prior_panel,
                                      meta=meta, q_position=pos, option_raw=raw,
                                      option_code="" if code is None else str(code),
                                      printed_scale_point="" if printed is None else str(printed),
                                      option_label=label or raw,
                                      option_label_norm=L.norm_text(label or raw), n_selected=n))
            dec, opts = scale_mod.resolve(fake_q, fake_opts, lex)
            if not dec["is_ordinal"]:
                continue
            base = tb = t2b = 0
            latent = []
            for o in opts:
                n = counts[o["option_raw"]]
                if o["is_sentinel"]:
                    continue
                base += n
                tb += n if o["is_top_box"] else 0
                t2b += n if o["is_top2_box"] else 0
                if o["latent_favourability"] is not None:
                    latent += [o["latent_favourability"]] * n
            if not base:
                continue
            out.append(dict(
                htr_panel=htr_panel, prior_panel=prior_panel,
                meta=match["meta"], prior_meta=meta, question_text=text[:80],
                prior_base=base, htr_base=match["base"],
                prior_points=dec["scale_max"], htr_points=match["scale_points"],
                prior_top_box=L.pct(tb, base), htr_top_box=match["top_box_pct"],
                prior_top2=L.pct(t2b, base), htr_top2=match["top2_box_pct"],
                prior_latent_mean=round(sum(latent) / len(latent), 1) if latent else None,
                htr_latent_mean=match["latent_mean"],
                latent_delta=(round(match["latent_mean"] - sum(latent) / len(latent), 1)
                              if latent else None)))
    return out


# --- 4. known-answer accuracy ------------------------------------------------

def known_answers(landed):
    questions = {q["question_key"]: q for q in read(os.path.join(landed, "dim_question.csv"))}
    out = []
    acc = {}
    for f in read(os.path.join(landed, "fct_response.csv")):
        q = questions.get(f["question_key"])
        if not q:
            continue
        for meta, rx, desc in KNOWN_ANSWERS:
            if q["meta"] != meta:
                continue
            answer = (f["option_labels"] or "") + " " + (f["qual_clean"] or "")
            if not answer.strip():
                continue
            a = acc.setdefault((f["panel"], meta, desc), dict(n=0, correct=0))
            a["n"] += 1
            a["correct"] += 1 if re.search(rx, answer, re.I) else 0
    for (panel, meta, desc), a in sorted(acc.items()):
        lo, hi = L.wilson(a["correct"], a["n"])
        out.append(dict(panel=panel, meta=meta, fact=desc, base=a["n"], correct=a["correct"],
                        accuracy_pct=L.pct(a["correct"], a["n"]),
                        ci_low=round(100 * lo, 1), ci_high=round(100 * hi, 1)))
    return out


# --- 5. drivers of theatrical intent ----------------------------------------

def drivers(landed, out_dir, banner_rows, min_n=60):
    """What travels with theatrical intent, by rank correlation.

    Correlation at n=273 on a synthetic panel with balanced-by-design demographics
    is a hypothesis generator, not a causal claim -- and the balance means the
    usual sampling-error interpretation does not apply either. Reported for
    direction and ordering only.
    """
    prose = read(os.path.join(out_dir, "prose_scores.csv"))
    intent = {r["archetype_id"]: int(r["score"]) for r in prose
              if r["meta"] == "DTHEAT" and r["score"]}
    if not intent:
        return []
    out = []

    # latent favourability of each closed-end metric vs intent
    decisions = {d["question_key"]: d for d in read(os.path.join(out_dir, "scale_map_questions.csv"))}
    smap = {(o["question_key"], o["option_raw"]): o for o in read(os.path.join(out_dir, "scale_map.csv"))}
    per_metric = defaultdict(dict)
    for f in read(os.path.join(landed, "fct_response_option.csv")):
        if f["panel"] != "AD" or f["archetype_id"] not in intent:
            continue
        d = decisions.get(f["question_key"])
        o = smap.get((f["question_key"], f["option_raw"]))
        if not d or not o or d["is_ordinal"] != "1" or d["scale_role"] != "favourability":
            continue
        if o["latent_favourability"]:
            per_metric[(d["meta"], d["q_position"], d["question_text"][:70])][f["archetype_id"]] = \
                float(o["latent_favourability"])
    for (meta, pos, text), vals in per_metric.items():
        ids = [i for i in vals if i in intent]
        if len(ids) < min_n:
            continue
        rho = L.spearman([vals[i] for i in ids], [intent[i] for i in ids])
        if rho is None:
            continue
        out.append(dict(kind="closed_end_metric", feature=f"{meta} (Q{pos})", detail=text,
                        n=len(ids), rho=round(rho, 3)))

    # theme mention (0/1) vs intent
    themes = defaultdict(set)
    for c in read(os.path.join(out_dir, "verbatim_codes.csv")):
        if c["panel"] == "AD":
            themes[c["theme_id"]].add(c["archetype_id"])
    ids_all = [i for i in intent]
    for tid, mentioners in sorted(themes.items()):
        xs = [1 if i in mentioners else 0 for i in ids_all]
        if min(sum(xs), len(xs) - sum(xs)) < 15:
            continue                      # too lopsided to correlate honestly
        rho = L.spearman(xs, [intent[i] for i in ids_all])
        if rho is None:
            continue
        out.append(dict(kind="theme_mention", feature=tid, detail=f"{sum(xs)} of {len(xs)} mention",
                        n=len(xs), rho=round(rho, 3)))
    out.sort(key=lambda r: -abs(r["rho"]))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default="out")
    ap.add_argument("--lexicon", default="conf/scale_lexicon.json")
    ap.add_argument("--min-base", type=int, default=30)
    a = ap.parse_args()

    landed = os.path.join(a.out, "landed")
    scale_mod = load_scale_module()
    banner_rows, shares = build_banner(landed, a.out, a.min_base)
    cross = cross_panel(banner_rows, option_label_overlap(landed, a.out))
    rep = replication(a.data, landed, a.out, banner_rows, scale_mod, a.lexicon)
    ka = known_answers(landed)
    drv = drivers(landed, a.out, banner_rows)

    L.write_csv(os.path.join(a.out, "banner.csv"), list(banner_rows[0]), banner_rows)
    if shares:
        L.write_csv(os.path.join(a.out, "banner_nominal_shares.csv"), list(shares[0]), shares)
    if cross:
        L.write_csv(os.path.join(a.out, "cross_panel_equated.csv"), list(cross[0]), cross)
    if rep:
        L.write_csv(os.path.join(a.out, "replication_vs_prior_wave.csv"), list(rep[0]), rep)
    if ka:
        L.write_csv(os.path.join(a.out, "known_answer_accuracy.csv"), list(ka[0]), ka)
    if drv:
        L.write_csv(os.path.join(a.out, "intent_drivers.csv"), list(drv[0]), drv)

    print(L.banner("ABR-HTR stage 6 -- analysis"))
    tot = [r for r in banner_rows if r["cut"] == "total"]
    print(f"  banner: {len(banner_rows):,} rows ({len(tot)} question x total), "
          f"{len(shares):,} nominal share rows")
    print(f"  cells below n={a.min_base} and flagged: "
          f"{sum(1 for r in banner_rows if r['base_flag']):,} of {len(banner_rows):,}")

    print("\n  HEADLINE -- adult panel, total (top box / top-2 / latent mean):")
    for r in sorted([r for r in tot if r["panel"] == "AD"], key=lambda r: -(r["latent_mean"] or 0))[:14]:
        print(f"    {r['meta']:<11} Q{r['q_position']:<3} n={r['base']:<4} "
              f"TB {r['top_box_pct']:>5.1f}% [{r['tb_ci_low']:>4.1f}-{r['tb_ci_high']:>4.1f}]  "
              f"T2B {pct_or_dash(r['top2_box_pct']):>6}  latent {r['latent_mean']:>5.1f}  "
              f"{r['question_text'][:46]}")

    print("\n  KIDS -- the same construct on two different instruments:")
    print(f"    {'meta':<11}{'K3 pts':>7}{'K9 pts':>7}{'ovlp':>6}{'K3 TB':>8}{'K9 TB':>8}{'raw gap':>9}"
          f"{'K3 lat':>8}{'K9 lat':>8}{'lat gap':>9}   verdict")
    for c in cross:
        print(f"    {c['meta']:<11}{c['k3_points']:>7}{c['k9_points']:>7}"
              f"{(c['option_label_overlap'] if c['option_label_overlap'] is not None else 0):>6.2f}"
              f"{c['k3_top_box']:>7.1f}%{c['k9_top_box']:>7.1f}%{c['raw_top_box_gap']:>9.1f}"
              f"{c['k3_latent_mean']:>8.1f}{c['k9_latent_mean']:>8.1f}{c['latent_gap']:>9.1f}   {c['verdict']}")

    if rep:
        print("\n  REPLICATION -- this wave vs the prior wave, identical wording, disjoint personas:")
        for panel in sorted({r["htr_panel"] for r in rep}):
            rows = [r for r in rep if r["htr_panel"] == panel]
            deltas = [r["latent_delta"] for r in rows if r["latent_delta"] is not None]
            rho = L.spearman([r["prior_latent_mean"] for r in rows],
                             [r["htr_latent_mean"] for r in rows])
            mad = round(sum(abs(d) for d in deltas) / len(deltas), 1) if deltas else None
            worst = sorted(rows, key=lambda r: -abs(r["latent_delta"] or 0))[:3]
            print(f"    {panel} vs {rows[0]['prior_panel']}: {len(rows)} matched constructs, "
                  f"rank-order rho={rho:.3f}, mean |latent delta|={mad} points")
            for w in worst:
                print(f"       largest move: {w['meta']:<10} {w['prior_latent_mean']:>5.1f} -> "
                      f"{w['htr_latent_mean']:>5.1f} ({w['latent_delta']:+.1f})  {w['question_text'][:44]}")

    if ka:
        print("\n  KNOWN-ANSWER ACCURACY -- scored against what the trailer actually said:")
        for r in ka:
            print(f"    {r['panel']} {r['meta']:<10} {r['accuracy_pct']:>5.1f}% "
                  f"[{r['ci_low']:>4.1f}-{r['ci_high']:>5.1f}] {r['correct']}/{r['base']}   {r['fact']}")

    if drv:
        print("\n  DRIVERS of theatrical intent (rank correlation, adult panel -- direction and "
              "ordering only, not causal):")
        for r in drv[:12]:
            print(f"    rho {r['rho']:>+6.3f}  n={r['n']:<4} {r['kind']:<19} {r['feature']:<22} {r['detail'][:40]}")

    print(f"\n  wrote banner.csv, banner_nominal_shares.csv, cross_panel_equated.csv, "
          f"replication_vs_prior_wave.csv, known_answer_accuracy.csv, intent_drivers.csv")


if __name__ == "__main__":
    main()
