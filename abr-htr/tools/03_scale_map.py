#!/usr/bin/env python3
"""Stage 3 -- decide what "top box" means, per question, and prove the decision.

This is the single highest-risk artefact in the build, so it is deterministic,
versioned, and it refuses to guess quietly.

Three facts about this wave force the design:

  1. Option codes exist but their direction is not fixed. `KPLIKE2` runs 1=best;
     `KPWANT` in the same file runs 5=best. A global "top box = code 1" rule
     reports the bottom box as the top box on half the battery.
  2. 22 questions print a second scale number inside the label
     (`2. 4 - To a great extent`) and on 20 of them it runs opposite to the code.
     The printed point is the questionnaire's scale; the code is an artefact of
     option ordering.
  3. K3 asks 3-point scales where K9 asks 5-point ones for the same construct.
     Counting boxes cannot cross them -- that is exactly how the prior wave's
     spurious "37-54 point appeal collapse" was manufactured. So every option
     also gets a 0-100 latent score, which can.

Resolution order per question: printed scale point -> lexicon ladder -> option
code (flagged). Favourability then flips for negative constructs ("Not at all"
is the *best* answer to "did any part feel boring?") and is distance-from-
optimum for the too-little/right-amount/too-much items.

Anything unresolved or self-contradictory goes to out/scale_review_queue.csv and
into a generated AI.GENERATE_TABLE pass -- never into a silent default.

  python3 tools/03_scale_map.py --out out [--theta 75]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re

import htr_lib as L


def load_lexicon(path):
    with open(path, encoding="utf-8") as fh:
        lex = json.load(fh)
    # longest phrase first so 'not at all' beats 'at all' and 'a little bit'
    # beats 'a little'
    lex["_ladder"] = sorted(lex["intensity"].items(), key=lambda kv: -len(kv[0]))
    lex["_sentinel"] = [L.norm_text(s) for s in lex["sentinel"]]
    lex["_nominal"] = {m.upper() for m in lex["nominal_metas"]}
    return lex


def is_sentinel(label, lex):
    n = L.norm_text(label)
    if not n:
        return False
    return any(n == s or n.startswith(s + " ") or f" {s}" in f" {n}" for s in lex["_sentinel"])


def lexicon_intensity(label, lex):
    """-> (score, matched_phrase) or (None, None) if nothing in the ladder matches."""
    n = L.norm_text(label)
    for phrase, score in lex["_ladder"]:
        if L.norm_text(phrase) in n:
            return score, phrase
    return None, None


WH_START = re.compile(r"^\s*(?:\[[^\]]*\]\s*)?(which|who|what kind|what type|where|whom)\b", re.I)


def scale_role(question_text, lex):
    """favourability | behavioural -- what the scale is FOR.

    Frequency, ownership and familiarity items are ordinal but they are cuts,
    not verdicts on the film. Ranking them is fine; publishing a 'top box' on
    religious attendance is not, so the role travels with the question.
    """
    t = L.norm_text(question_text)
    return "behavioural" if any(t.startswith(L.norm_text(s)) for s in lex.get("behavioural_stems", [])) \
        else "favourability"


def construct_polarity(question_text, lex):
    t = L.norm_text(question_text)
    for p in lex["mid_optimal_constructs"]:
        if L.norm_text(p) in t:
            return "mid_optimal"
    for p in lex["negative_constructs"]:
        if L.norm_text(p) in t:
            return "negative"
    return "positive"


def resolve(question, options, lex):
    """Rank one question's options. Returns (decision dict, list of option dicts)."""
    meta = (question["meta"] or "").upper()
    polarity = construct_polarity(question["question_text"], lex)
    live, sentinels = [], []
    for o in options:
        (sentinels if is_sentinel(o["option_label"], lex) else live).append(o)

    flags = []
    # A wh-question whose options the intensity ladder cannot place is a
    # nominal pick list (who would you watch with, what kind of movie is this).
    # Forcing a rank onto one manufactures a scale that the questionnaire never
    # asked -- report these as option shares instead.
    lex_cover = sum(1 for o in live if lexicon_intensity(o["option_label"], lex)[0] is not None)
    wh_nominal = bool(WH_START.match(question["question_text"] or "")) and \
        lex_cover < max(2, int(0.6 * max(len(live), 1)))
    nominal = meta in lex["_nominal"] or question["channel"] == "multi_select" or wh_nominal

    # intensity, by the strongest available basis
    printed = [o for o in live if o["printed_scale_point"] not in ("", None)]
    lex_hits = {}
    for o in live:
        s, phrase = lexicon_intensity(o["option_label"], lex)
        if s is not None:
            lex_hits[o["option_raw"]] = (s, phrase)

    if len(live) < 2:
        # One observed option is not a scale. These are known-answer checks
        # (everyone said "in a movie theatre", which is what the trailer said)
        # or screener flags -- usable as evidence, never as a banner row.
        basis = "single_option_observed"
        for o in live:
            o["_intensity"] = None
            o["_basis_note"] = "single observed option -- zero variance"
    elif len(printed) >= 2 and len(printed) == len(live):
        basis = "printed_scale_point"
        for o in live:
            o["_intensity"] = float(o["printed_scale_point"])
            o["_basis_note"] = f"printed {o['printed_scale_point']}"
    elif len(lex_hits) == len(live) and len(live) >= 2:
        basis = "lexicon"
        for o in live:
            s, phrase = lex_hits[o["option_raw"]]
            o["_intensity"] = s
            o["_basis_note"] = f"lexicon '{phrase}'"
    elif nominal:
        basis = "nominal"
        for o in live:
            o["_intensity"] = None
            o["_basis_note"] = "nominal"
    elif len(lex_hits) >= max(2, int(0.6 * len(live))):
        basis = "lexicon_partial"
        flags.append(f"lexicon covers {len(lex_hits)}/{len(live)} options")
        # unmatched options cannot be placed; they stay unranked rather than
        # being dropped into an arbitrary position
        for o in live:
            hit = lex_hits.get(o["option_raw"])
            o["_intensity"] = hit[0] if hit else None
            o["_basis_note"] = f"lexicon '{hit[1]}'" if hit else "unmatched"
    elif len(live) >= 2 and all(o["option_code"] not in ("", None) for o in live):
        basis = "option_code"
        flags.append("ranked by option code only -- direction unverified")
        for o in live:
            o["_intensity"] = -float(o["option_code"])   # assume 1 = most, flagged
            o["_basis_note"] = f"code {o['option_code']}"
    else:
        basis = "unresolved"
        flags.append("no basis for an order")
        for o in live:
            o["_intensity"] = None
            o["_basis_note"] = "unresolved"

    # cross-check: does the code order agree with the chosen basis?
    if basis in ("printed_scale_point", "lexicon") and len(live) >= 3:
        codes = [float(o["option_code"]) for o in live if o["option_code"] not in ("", None)]
        ints = [o["_intensity"] for o in live if o["option_code"] not in ("", None)]
        rho = L.spearman(codes, ints)
        if rho is not None and rho > 0.5:
            code_dir = "code_ascending_with_intensity"
        elif rho is not None and rho < -0.5:
            code_dir = "code_descending_with_intensity"
        else:
            code_dir = "code_unordered"
            flags.append(f"option code does not track intensity (rho={rho:.2f})" if rho is not None
                         else "option code order indeterminate")
    else:
        code_dir = "n/a"

    dup = {}
    for o in options:
        if o["option_code"] in ("", None):
            continue
        dup.setdefault(o["option_code"], set()).add(o["option_label_norm"])
    for c, labels in dup.items():
        if len(labels) > 1:
            flags.append(f"code {c} carries {len(labels)} different labels")

    # The questionnaire and the export can disagree about which option list
    # belongs to a question. AD's TRCONT battery asks
    # "too little / the right amount / too much" but carries agree/disagree
    # labels -- there is no honest ranking of that, so refuse to invent one.
    if polarity == "mid_optimal":
        labels = " ".join(L.norm_text(o["option_label"]) for o in live)
        if "agree" in labels and not any(k in labels for k in ("right amount", "too much", "too little")):
            flags.append("option labels are an agree/disagree battery but the question asks "
                         "too little / right amount / too much -- wrong option list attached")
            basis = "label_question_mismatch"
            for o in live:
                o["_intensity"] = None
                o["_basis_note"] = "labels do not match the question"

    # favourability from intensity + polarity
    ranked = [o for o in live if o.get("_intensity") is not None]
    if basis not in ("nominal", "label_question_mismatch") and ranked:
        if polarity == "negative":
            ranked.sort(key=lambda o: o["_intensity"])            # least intense = best
        elif polarity == "mid_optimal":
            mid = sorted(o["_intensity"] for o in ranked)[len(ranked) // 2]
            ranked.sort(key=lambda o: (abs(o["_intensity"] - mid), -o["_intensity"]))
        else:
            ranked.sort(key=lambda o: -o["_intensity"])           # most intense = best
        # Dense ranking over DISTINCT positions, not over options. Two options
        # that share a printed scale point are one scale position -- AD Q25 has
        # a stray 'Neither agree nor disagree' variant sitting on printed 3, and
        # ranking per option would silently turn a 5-point scale into a 6-point
        # one and move its top box.
        order = []
        for o in ranked:
            v = o["_intensity"]
            if v not in order:
                order.append(v)
        R = len(order)
        rank_of = {v: i + 1 for i, v in enumerate(order)}
        # Latent scoring. Where the label prints its own scale point we know the
        # instrument's full scale (a printed 5 means a 5-point scale), so anchor
        # the 0-100 axis to 1..max_printed rather than to the options that
        # happened to be chosen. Otherwise an unpicked option would stretch the
        # remaining ones and make two panels look further apart than they are.
        printed_anchor = None
        if basis == "printed_scale_point" and polarity == "positive":
            top = max(o["_intensity"] for o in ranked)
            if top > 1:
                printed_anchor = top
        for o in ranked:
            i = rank_of[o["_intensity"]]
            o["favourability_rank"] = i
            if printed_anchor:
                o["latent_favourability"] = round(100.0 * (o["_intensity"] - 1) / (printed_anchor - 1), 1)
            else:
                o["latent_favourability"] = round(100.0 * (R - i) / (R - 1), 1) if R > 1 else 100.0
            o["is_top_box"] = int(i == 1)
            o["is_top2_box"] = int(i <= 2 and R >= 3)
            o["is_bottom_box"] = int(i == R)
            o["is_bottom2_box"] = int(i >= R - 1 and R >= 3)
    n_positions = len({o["_intensity"] for o in ranked}) if ranked else 0
    for o in options:
        o.setdefault("favourability_rank", None)
        o.setdefault("latent_favourability", None)
        for k in ("is_top_box", "is_top2_box", "is_bottom_box", "is_bottom2_box"):
            o.setdefault(k, 0)
        o["is_sentinel"] = int(o in sentinels)
        if o in sentinels:
            o["_basis_note"] = "sentinel (excluded from box maths and scale_max)"
        o["rank_basis"] = basis
        o["intensity"] = o.pop("_intensity", None)
        o["basis_note"] = o.pop("_basis_note", "")

    needs_review = (bool(flags) or basis in ("option_code", "unresolved", "lexicon_partial")) \
        and basis not in ("nominal", "single_option_observed")
    decision = dict(
        question_key=question["question_key"], panel=question["panel"], meta=question["meta"],
        q_position=question["q_position"], q_type=question["q_type"], channel=question["channel"],
        question_text=question["question_text"], construct_polarity=polarity,
        rank_basis=basis, code_direction=code_dir,
        scale_role=("nominal" if basis == "nominal" else scale_role(question["question_text"], lex)),
        is_ordinal=int(basis not in ("nominal", "single_option_observed", "label_question_mismatch")
                       and bool(ranked)),
        n_options=len(options), n_ranked=len(ranked), n_sentinel=len(sentinels),
        scale_max=n_positions,
        flags="; ".join(flags), needs_review=int(needs_review))
    return decision, options


AI_PROMPT = """You are equating survey scales for a film-trailer concept test.

Question ({panel}, {meta}): {question_text}

Options as exported (the leading number is an export code whose direction is NOT
reliable; some labels print their own scale point):
{options}

Rank these options from most favourable to the film (rank 1) to least favourable.
Judge favourability toward the film, not intensity of the word: for a question
about something undesirable (boring, scary, confusing, too long), "Not at all" is
the MOST favourable answer. For "too little / the right amount / too much" items,
"the right amount" is the most favourable and both extremes are less so.

Mark any option that is not part of the ordered scale (don't know, not sure,
other, something else, none of the above, prefer not to say) as sentinel = true;
sentinels get no rank.

Return one row per option: option_raw, rank (integer, 1 = most favourable, null
for sentinels), sentinel (bool), latent_favourability (0-100, 100 = most
favourable, null for sentinels), reasoning (one short clause)."""


def emit_ai_pass(review, out_dir, project="PROJECT_ID"):
    d = os.path.join(out_dir, "load")
    os.makedirs(d, exist_ok=True)
    prompts = []
    for q in review:
        opts = "\n".join(f"  - {o['option_raw']}" for o in q["options"])
        prompts.append(dict(question_key=q["decision"]["question_key"],
                            panel=q["decision"]["panel"], meta=q["decision"]["meta"],
                            flags=q["decision"]["flags"],
                            prompt=AI_PROMPT.format(options=opts, **{
                                k: q["decision"][k] for k in ("panel", "meta", "question_text")})))
    with open(os.path.join(out_dir, "scale_ai_prompts.jsonl"), "w", encoding="utf-8") as fh:
        for p in prompts:
            fh.write(json.dumps(p) + "\n")

    sql = f"""-- Stage 3b: AI ranking for the {len(prompts)} questions the deterministic
-- pass could not resolve or flagged as self-contradictory. It does NOT re-rank
-- the rest: a question already pinned by its printed scale point does not need
-- a model's opinion, and paying for one invites drift.
--
-- Prompt text is versioned in tools/03_scale_map.py (AI_PROMPT) and mirrored in
-- out/scale_ai_prompts.jsonl. A silent prompt edit re-ranks the study and
-- nothing in the output looks different -- so change it in git or not at all.
--
-- temperature 0, and run it TWICE into two tables before trusting it
-- (see 05b_validate_scale_map.sql).

CREATE OR REPLACE TABLE `{project}.htr_40_semantic.ai_scale_rank` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `{project}.htr_40_semantic.gemini_flash`,
  (
    SELECT
      question_key,
      panel,
      meta,
      CONCAT(
        'You are equating survey scales for a film-trailer concept test.\\n\\n',
        'Question (', panel, ', ', meta, '): ', question_text, '\\n\\n',
        'Options as exported (the leading number is an export code whose direction is NOT reliable; ',
        'some labels print their own scale point):\\n', option_block, '\\n\\n',
        'Rank these options from most favourable to the film (rank 1) to least favourable. ',
        'Judge favourability toward the film, not intensity of the word: for a question about ',
        'something undesirable (boring, scary, confusing, too long), "Not at all" is the MOST ',
        'favourable answer. For "too little / the right amount / too much" items, "the right amount" ',
        'is most favourable and both extremes are less so.\\n',
        'Mark any option outside the ordered scale (don''t know, not sure, other, something else, ',
        'none of the above, prefer not to say) as sentinel = true; sentinels get no rank.'
      ) AS prompt
    FROM `{project}.htr_20_curated.dim_question_review`
  ),
  STRUCT(
    'option_raw STRING, rank INT64, sentinel BOOL, latent_favourability FLOAT64, reasoning STRING'
      AS output_schema,
    0.0 AS temperature
  )
);
"""
    with open(os.path.join(d, "05_ai_scale_rank.sql"), "w", encoding="utf-8") as fh:
        fh.write(sql)

    validate = f"""-- Stage 3c: validate the AI ranking BEFORE any mart uses it.
-- A ranking that fails these is a bug, not a result.

-- 1. every non-sentinel option got a rank, and ranks are 1..n with no gaps
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT question_key,
           COUNTIF(NOT sentinel) AS n_ranked,
           COUNT(DISTINCT IF(NOT sentinel, rank, NULL)) AS n_distinct_ranks,
           MAX(IF(NOT sentinel, rank, NULL)) AS max_rank
    FROM `{project}.htr_40_semantic.ai_scale_rank`
    GROUP BY question_key
    HAVING n_ranked != n_distinct_ranks OR max_rank != n_ranked
  )
) = 0 AS 'AI ranking is not a strict 1..n permutation for some question';

-- 2. latent favourability is monotonic in rank within each question
ASSERT (
  SELECT COUNT(*) FROM (
    SELECT a.question_key
    FROM `{project}.htr_40_semantic.ai_scale_rank` a
    JOIN `{project}.htr_40_semantic.ai_scale_rank` b
      ON a.question_key = b.question_key AND a.rank < b.rank
    WHERE NOT a.sentinel AND NOT b.sentinel
      AND a.latent_favourability <= b.latent_favourability
  )
) = 0 AS 'latent favourability is not monotonic in rank';

-- 3. stability: run 05_ai_scale_rank.sql a second time into ai_scale_rank_run2
--    at temperature 0 and require the two runs to agree exactly.
ASSERT (
  SELECT COUNT(*)
  FROM `{project}.htr_40_semantic.ai_scale_rank` a
  FULL JOIN `{project}.htr_40_semantic.ai_scale_rank_run2` b
    USING (question_key, option_raw)
  WHERE a.rank IS DISTINCT FROM b.rank OR a.sentinel IS DISTINCT FROM b.sentinel
) = 0 AS 'AI ranking is not stable across two runs at temperature 0';

-- 4. where the deterministic pass DID resolve a question, the model must agree.
--    Disagreement means one of the two is wrong; look before overriding either.
SELECT d.question_key, d.option_raw, d.favourability_rank AS deterministic_rank, a.rank AS ai_rank
FROM `{project}.htr_20_curated.dim_question_option_scaled` d
JOIN `{project}.htr_40_semantic.ai_scale_rank` a
  USING (question_key, option_raw)
WHERE d.rank_basis IN ('printed_scale_point', 'lexicon')
  AND d.favourability_rank IS DISTINCT FROM a.rank
ORDER BY d.question_key, d.option_raw;
"""
    with open(os.path.join(d, "05b_validate_scale_map.sql"), "w", encoding="utf-8") as fh:
        fh.write(validate)
    return len(prompts)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="out")
    ap.add_argument("--lexicon", default="conf/scale_lexicon.json")
    ap.add_argument("--theta", type=float, default=75.0,
                    help="latent threshold for equated top box (default 75)")
    ap.add_argument("--project", default="PROJECT_ID")
    a = ap.parse_args()

    lex = load_lexicon(a.lexicon)
    landed = os.path.join(a.out, "landed")
    questions = {q["question_key"]: q for q in csv.DictReader(open(os.path.join(landed, "dim_question.csv"), encoding="utf-8"))}
    opts_by_q = {}
    for o in csv.DictReader(open(os.path.join(landed, "dim_question_option.csv"), encoding="utf-8")):
        opts_by_q.setdefault(o["question_key"], []).append(o)

    decisions, all_options, review = [], [], []
    for qk, q in questions.items():
        if q["channel"] == "open_end":
            continue
        opts = opts_by_q.get(qk, [])
        if not opts:
            continue
        dec, opts = resolve(q, opts, lex)
        # equated boxes at a common latent threshold -- this is what lets a
        # 3-point K3 scale sit in the same row as a 5-point K9 scale
        for o in opts:
            lf = o["latent_favourability"]
            o["is_equated_top_box"] = int(lf is not None and lf >= a.theta)
            o["is_equated_top2_box"] = int(lf is not None and lf >= 50.0)
        decisions.append(dec)
        all_options.extend(opts)
        if dec["needs_review"]:
            review.append(dict(decision=dec, options=opts))

    ocols = ["question_key", "panel", "meta", "q_position", "option_raw", "option_code",
             "printed_scale_point", "option_label", "option_label_norm", "n_selected",
             "rank_basis", "basis_note", "intensity", "favourability_rank",
             "latent_favourability", "is_sentinel", "is_top_box", "is_top2_box",
             "is_bottom_box", "is_bottom2_box", "is_equated_top_box", "is_equated_top2_box"]
    L.write_csv(os.path.join(a.out, "scale_map.csv"), ocols, all_options)
    L.write_csv(os.path.join(a.out, "scale_map_questions.csv"), list(decisions[0]), decisions)
    rq = [dict(d["decision"], options="; ".join(o["option_raw"] for o in d["options"])) for d in review]
    L.write_csv(os.path.join(a.out, "scale_review_queue.csv"), list(rq[0]) if rq else ["question_key"], rq)
    with open(os.path.join(a.out, "scale_map.json"), "w", encoding="utf-8") as fh:
        json.dump(dict(theta=a.theta, lexicon=os.path.abspath(a.lexicon),
                       questions=decisions, options=all_options), fh, indent=1)
    n_ai = emit_ai_pass(review, a.out, a.project)

    basis = {}
    for d in decisions:
        basis[d["rank_basis"]] = basis.get(d["rank_basis"], 0) + 1
    pol = {}
    for d in decisions:
        pol[d["construct_polarity"]] = pol.get(d["construct_polarity"], 0) + 1
    print(L.banner("ABR-HTR stage 3 -- scale map"))
    print(f"  closed-end questions resolved: {len(decisions)}   options: {len(all_options)}")
    print(f"  rank basis: {basis}")
    print(f"  construct polarity: {pol}")
    print(f"  ordinal questions: {sum(d['is_ordinal'] for d in decisions)}  "
          f"sentinels excluded: {sum(d['n_sentinel'] for d in decisions)}")
    print(f"  equated top box threshold: latent >= {a.theta}")
    print(f"  NEEDS REVIEW: {len(review)} questions -> out/scale_review_queue.csv "
          f"({n_ai} prompts in out/scale_ai_prompts.jsonl, SQL in out/load/05_ai_scale_rank.sql)")
    for d in decisions:
        if d["needs_review"]:
            print(f"    {d['panel']} Q{d['q_position']:<3} {d['meta']:<12} [{d['rank_basis']}] {d['flags']}")


if __name__ == "__main__":
    main()
