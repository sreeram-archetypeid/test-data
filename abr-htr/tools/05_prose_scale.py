#!/usr/bin/env python3
"""Stage 5 -- score the prose-only headline metrics onto a comparable scale.

Ten of the adult panel's headline metrics have no closed-end at all. Appeal,
appeal to a child, likelihood a child asks to see it, recommend (parent and
non-parent), theatrical intent, streaming intent and category interest all
arrive as sentences. Until they are scored they cannot appear in a banner, and
the study's most commercially important numbers are exactly these.

This stage produces a deterministic baseline against conf/prose_rubrics.json:
one score per persona per metric, plus the cue that produced it and a confidence
grade. It is not a replacement for the AI pass -- it is what makes the AI pass
checkable, because you know the expected distribution before you spend a call.

It also cross-checks itself against the aat_* block, which carries the
generator's own view of the same constructs (aat_opening_weekend_intent for
theatrical intent, aat_top_box_category for overall interest). Two independent
readings of the same persona agreeing is evidence; disagreeing is a finding.

  python3 tools/05_prose_scale.py --out out
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re

import htr_lib as L

WINDOW = 4          # words before a cue that a negation can reach


def load_rubrics(path):
    with open(path, encoding="utf-8") as fh:
        r = json.load(fh)
    for fam in r["families"].values():
        for c in fam["cues"]:
            c["_rx"] = re.compile(c["rx"], re.I)
    r["_metric_family"] = {m: name for name, fam in r["families"].items() for m in fam["metrics"]}
    r["_neg"] = re.compile(r"\b(" + "|".join(re.escape(n) for n in r["negations"]) + r")\b", re.I)
    r["_na"] = re.compile(r["not_applicable"], re.I)
    return r


def negated(text, start):
    """Is there a negation in the few words before this cue?"""
    prefix = text[:start].split()
    return bool(prefix) and any(re.fullmatch(
        r"(not|no|never|hardly|barely|wouldn'?t|don'?t|isn'?t|doubt|unlikely)",
        w.strip(".,;:!?").lower()) for w in prefix[-WINDOW:])


def score_text(text, family, rubrics):
    """-> (score, confidence, evidence). None score when nothing matches."""
    if rubrics["_na"].match(text):
        # The persona said the question does not apply to them. That is not a
        # failed score -- it is the respondent correcting a base the harness got
        # wrong by forcing everyone down both the parent and non-parent paths.
        return None, "not_applicable", "respondent marked not applicable"
    fam = rubrics["families"][family]
    hits = []
    for c in fam["cues"]:
        for m in c["_rx"].finditer(text):
            s = c["score"]
            flip = negated(text, m.start())
            if flip:
                s = 6 - s                      # 5 -> 1, 4 -> 2, 3 -> 3
            hits.append((abs(c["score"] - 3), s, m.group(0), flip))
    if not hits:
        return None, "unscored", ""
    hits.sort(key=lambda h: -h[0])             # most extreme cue is the most informative
    top = hits[0]
    scores = {h[1] for h in hits}
    if len(hits) == 1:
        conf = "medium"
    elif len(scores) == 1:
        conf = "high"
    elif max(scores) - min(scores) >= 3:
        conf = "low"                           # the sentence says two opposite things
    else:
        conf = "medium"
    ev = f"'{top[2]}'" + (" (negated)" if top[3] else "")
    if len(hits) > 1:
        ev += f" +{len(hits) - 1} more cue(s)"
    return top[1], conf, ev


AAT_CROSSCHECK = {
    # metric -> (aat column, mapping of its values to a 1-5 score)
    "DTHEAT": ("aat_opening_weekend_intent",
               {"opening weekend theater": 5, "wait for streaming": 2, "never watch": 1}),
    "POSTAPPEAL": ("aat_top_box_category",
                   {"definitely interested": 5, "probably interested": 4,
                    "probably not interested": 2, "definitely not interested": 1}),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="out")
    ap.add_argument("--rubrics", default="conf/prose_rubrics.json")
    ap.add_argument("--project", default="PROJECT_ID")
    a = ap.parse_args()

    rub = load_rubrics(a.rubrics)
    landed = os.path.join(a.out, "landed")
    questions = {q["question_key"]: q for q in
                 csv.DictReader(open(os.path.join(landed, "dim_question.csv"), encoding="utf-8"))}
    aat = {r["archetype_id"]: r for r in
           csv.DictReader(open(os.path.join(landed, "dim_aat.csv"), encoding="utf-8"))}

    scored, unmapped = [], {}
    for f in csv.DictReader(open(os.path.join(landed, "fct_response.csv"), encoding="utf-8")):
        if f["channel"] != "open_end":
            continue
        text = f["qual_clean"].strip()
        if not text:
            continue
        q = questions.get(f["question_key"], {})
        meta = q.get("meta", "")
        fam = rub["_metric_family"].get(meta)
        if not fam:
            # only track questions that LOOK like scales but have no rubric --
            # a genuinely open question needs no score
            if re.search(r"\b(how appealing|how likely|how interested|how comfortable|how well)\b",
                         q.get("question_text", ""), re.I):
                unmapped[meta] = q.get("question_text", "")[:90]
            continue
        s, conf, ev = score_text(text, fam, rub)
        row = dict(archetype_id=f["archetype_id"], panel=f["panel"], meta=meta, family=fam,
                   question_text=q.get("question_text", "")[:110], score=s, confidence=conf,
                   evidence=ev, n_chars=len(text), text=text[:300])
        col, mapping = AAT_CROSSCHECK.get(meta, (None, None))
        if col:
            av = L.norm_text((aat.get(f["archetype_id"], {}) or {}).get(col, ""))
            row["aat_column"] = col
            row["aat_value"] = av
            row["aat_score"] = mapping.get(av)
            row["aat_agrees"] = (None if (s is None or mapping.get(av) is None)
                                 else int(abs(s - mapping[av]) <= 1))
        scored.append(row)

    if not scored:
        L.die("no prose metrics found -- check conf/prose_rubrics.json metric names against dim_question.meta")

    L.write_csv(os.path.join(a.out, "prose_scores.csv"), L_union(scored), scored)
    un = [r for r in scored if r["score"] is None and r["confidence"] != "not_applicable"]
    if un:
        L.write_csv(os.path.join(a.out, "prose_unscored.csv"),
                    ["archetype_id", "panel", "meta", "confidence", "text"], un)
    emit_ai_sql(rub, a.out, a.project)

    # ---- report -------------------------------------------------------------
    print(L.banner("ABR-HTR stage 5 -- prose metrics scored"))
    metrics = {}
    for r in scored:
        metrics.setdefault((r["panel"], r["meta"]), []).append(r)
    print(f"  {'panel':<6}{'metric':<12}{'base':>6}{'scored':>8}{'TB%':>8}{'T2B%':>8}{'mean':>7}"
          f"{'conf hi/med/lo':>16}   aat agreement")
    for (panel, meta), rows in sorted(metrics.items()):
        got = [r for r in rows if r["score"] is not None]
        n = len(got)
        tb = sum(1 for r in got if r["score"] == 5)
        t2b = sum(1 for r in got if r["score"] >= 4)
        mean = round(sum(r["score"] for r in got) / n, 2) if n else None
        lo, hi = L.wilson(tb, n)
        conf = {c: sum(1 for r in got if r["confidence"] == c) for c in ("high", "medium", "low")}
        na = sum(1 for r in rows if r["confidence"] == "not_applicable")
        agree = [r["aat_agrees"] for r in got if r.get("aat_agrees") is not None]
        ag = f"{L.pct(sum(agree), len(agree))}% of {len(agree)}" if agree else "-"
        print(f"  {panel:<6}{meta:<12}{len(rows) - na:>6}{n:>8}{L.pct(tb, n):>7}%{L.pct(t2b, n):>7}%"
              f"{mean if mean is not None else '-':>7}"
              f"{conf['high']:>6}/{conf['medium']}/{conf['low']:<6}   {ag}")
        if n:
            miss = len(rows) - na - n
            print(f"        top box 95% CI [{100*lo:.1f}, {100*hi:.1f}]"
                  + (f"   not applicable: {na}" if na else "")
                  + (f"   UNSCORED {miss}" if miss else ""))
    na_all = sum(1 for r in scored if r["confidence"] == "not_applicable")
    total = len(scored) - na_all
    ok = sum(1 for r in scored if r["score"] is not None)
    print(f"\n  coverage: {ok:,}/{total:,} ({L.pct(ok, total)}%) of applicable prose answers scored"
          f"   ({na_all:,} marked not applicable by the respondent)")
    print(f"  low-confidence scores: {sum(1 for r in scored if r['confidence'] == 'low'):,} "
          "(the sentence carries cues pointing both ways -- read these before publishing)")
    if unmapped:
        print("\n  scale-shaped prose questions with NO rubric -- add them to conf/prose_rubrics.json:")
        for meta, text in sorted(unmapped.items()):
            print(f"    {meta:<12} {text}")
    print(f"\n  wrote prose_scores.csv, prose_unscored.csv, out/load/08_ai_prose_score.sql")


def L_union(rows):
    seen = []
    for r in rows:
        for k in r:
            if k not in seen:
                seen.append(k)
    return seen


def emit_ai_sql(rub, out_dir, project):
    d = os.path.join(out_dir, "load")
    os.makedirs(d, exist_ok=True)
    anchors = "\\n".join(f"  {k} = {v}" for k, v in sorted(rub["scale"].items(), reverse=True))
    sql = f"""-- Stage 5b: score the prose-only metrics in-warehouse.
--
-- Run tools/05_prose_scale.py FIRST. It gives you the expected distribution per
-- metric from a rubric you can read, so when this pass returns a top box 20
-- points away you know to look at the prompt rather than at the film.
--
-- The rubric text below is generated from conf/prose_rubrics.json. Keep the two
-- in step: a prompt edited only here re-scores the study and nothing in the
-- output looks different.

CREATE OR REPLACE TABLE `{project}.htr_40_semantic.ai_prose_score` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `{project}.htr_40_semantic.gemini_flash`,
  (
    SELECT
      archetype_id, panel, meta, question_text, qual_clean,
      CONCAT(
        'A respondent answered a scale question in prose. Place the answer on the ',
        '5-point scale below, using only what the answer says.\\n\\n',
        'Scale:\\n{anchors}\\n\\n',
        'Rules: a conditional answer ("if the reviews are good") is 3. An answer that ',
        'defers to home viewing ("I would wait for streaming") is 2 for a theatrical ',
        'question, not a 4. Quote the span you scored from. If the answer does not ',
        'address the question, return score = NULL.\\n\\n',
        'Question: ', question_text, '\\n',
        'Answer: ', qual_clean
      ) AS prompt
    FROM `{project}.htr_20_curated.v_prose_metric`
  ),
  STRUCT(
    'score INT64, confidence STRING, evidence_span STRING' AS output_schema,
    0.0 AS temperature
  )
);

-- Compare against the deterministic baseline before anything downstream uses it.
-- Rows where the two differ by 2+ points are where a human should look:
--
-- SELECT b.meta, b.archetype_id, b.score AS rubric_score, a.score AS ai_score,
--        b.evidence AS rubric_cue, a.evidence_span, b.text
-- FROM `{project}.htr_30_marts.prose_scores_rubric` b
-- JOIN `{project}.htr_40_semantic.ai_prose_score` a USING (archetype_id, meta)
-- WHERE ABS(b.score - a.score) >= 2
-- ORDER BY ABS(b.score - a.score) DESC;
--
-- And against the generator's own view, which is independent of both:
--
-- SELECT meta,
--        COUNTIF(score >= 4) / COUNT(*) AS t2b_ai,
--        COUNTIF(aat_score >= 4) / COUNT(*) AS t2b_aat
-- FROM ... GROUP BY meta;
"""
    with open(os.path.join(d, "08_ai_prose_score.sql"), "w", encoding="utf-8") as fh:
        fh.write(sql)


if __name__ == "__main__":
    main()
