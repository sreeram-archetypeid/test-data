#!/usr/bin/env python3
"""Stage 4 -- semantics and themes over the 7,277 verbatims and the aat prose.

Three passes, in this order, because each one checks the one before it:

  1. Hygiene. Strip roleplay stage directions ('[hides face in my shirt]'),
     quarantine any generation-harness JSON, and drop instruction screens that
     are not questions. 2,545 HTR verbatims carry stage directions; left in,
     they dominate the vector space and every cluster becomes a cluster of
     gestures rather than of opinions. The direction count is kept, because
     embodiment is itself a signal worth reporting.
  2. Codeframe coding. Deterministic, multi-label, versioned in
     conf/codeframe.json. Every hit records the pattern that fired, so any
     number in the output can be traced to the sentence that produced it.
  3. Emergent clustering. TF-IDF + spherical k-means with no codeframe at all,
     then a coverage check: clusters the codeframe barely touches are reported
     as gaps. This is how you find the theme nobody thought to seed -- which in
     the prior wave was the audio/sensory complaint that no closed-end option
     could capture.

Incidence is reported per persona, not per verbatim: a persona who mentions the
dog four times is one mention, otherwise the talkative personas set the agenda.
Every percentage carries a Wilson interval and a base-size flag.

  python3 tools/04_semantic_themes.py --out out [--clusters 12]
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import re

import htr_lib as L

# aat_* columns that are per-persona prose worth coding alongside the verbatims.
AAT_PROSE = [
    "aat_opening_pact_promise", "aat_outrage_trigger", "aat_crossover_alienation",
    "aat_lifecycle_reaction", "aat_genre_contract", "aat_expectation_delta",
    "aat_confusion_vs_intrigue", "aat_event_density_stretch_snap", "aat_subjective_pacing",
    "aat_second_screen", "aat_parasocial_attachment", "aat_peak_end_override",
    "aat_playability_recommend",
]
# Not data: an instruction screen that carries 'responses' because the harness
# answered it anyway (ABR-TSR N6).
NOT_A_QUESTION = re.compile(r"^(next, you will watch|please watch|now you will)", re.I)
# "Nothing, I loved the dog!" is a null complaint, not a complaint about the dog.
# Without this, the dislike read shows DOG_ANIMAL at 46% and means nothing.
NULL_RESPONSE = re.compile(
    r"^\s*(nothing|none|no+|nope|not really|nah|nothing at all|nothing much|"
    r"i liked (it all|everything)|everything was (good|great|fine)|"
    r"i did ?n[o']?t dislike|there was ?n[o']?t anything|no complaints)\b", re.I)


def load_roles(path):
    """Question metas -> the read they support. See conf/question_roles.json for
    why incidence without a role is a number nobody can use."""
    with open(path, encoding="utf-8") as fh:
        roles = json.load(fh)["roles"]
    return roles


def roles_for(field, roles):
    out = ["any"]
    for role, metas in roles.items():
        for m in metas:
            if field == m or (m.endswith("_") and field.startswith(m)):
                out.append(role)
                break
    return out


def load_codeframe(path):
    with open(path, encoding="utf-8") as fh:
        cf = json.load(fh)
    for t in cf["themes"]:
        t["_rx"] = [(p, re.compile(p, re.I)) for p in t["patterns"]]
    return cf


def code_text(text, cf):
    """-> [(theme_id, polarity, matched_pattern)] -- multi-label, first hit per theme."""
    hits = []
    for t in cf["themes"]:
        for pat, rx in t["_rx"]:
            if rx.search(text):
                hits.append((t["id"], t["polarity"], pat))
                break
    return hits


def build_corpus(landed_dir):
    questions = {q["question_key"]: q for q in
                 csv.DictReader(open(os.path.join(landed_dir, "dim_question.csv"), encoding="utf-8"))}
    docs = []
    for f in csv.DictReader(open(os.path.join(landed_dir, "fct_response.csv"), encoding="utf-8")):
        text = f["qual_clean"].strip()
        if not text:
            continue
        q = questions.get(f["question_key"], {})
        if NOT_A_QUESTION.match(q.get("question_text", "")):
            continue                                    # instruction screen, not data
        if f["is_harness_leak"] == "1":
            continue                                    # quarantined
        docs.append(dict(
            doc_id=f"{f['panel']}:{f['archetype_id']}:{f['q_position']}",
            archetype_id=f["archetype_id"], panel=f["panel"], cohort=f["cohort"],
            source="verbatim", field=q.get("meta", ""), q_position=f["q_position"],
            question_text=q.get("question_text", ""), text=text,
            n_stage_directions=int(f["n_stage_directions"] or 0), n_chars=len(text)))
    for a in csv.DictReader(open(os.path.join(landed_dir, "dim_aat.csv"), encoding="utf-8")):
        for col in AAT_PROSE:
            text = (a.get(col) or "").strip()
            if not text or text in ("Low", "Med", "High"):
                continue
            clean, n_dir, _ = L.strip_stage_directions(text)
            docs.append(dict(
                doc_id=f"{a['panel']}:{a['archetype_id']}:{col}",
                archetype_id=a["archetype_id"], panel=a["panel"], cohort="",
                source="aat_prose", field=col, q_position="",
                question_text=col, text=clean,
                n_stage_directions=n_dir, n_chars=len(clean)))
    return docs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="out")
    ap.add_argument("--codeframe", default="conf/codeframe.json")
    ap.add_argument("--roles", default="conf/question_roles.json")
    ap.add_argument("--clusters", type=int, default=12)
    ap.add_argument("--min-base", type=int, default=30)
    ap.add_argument("--project", default="PROJECT_ID")
    a = ap.parse_args()

    landed = os.path.join(a.out, "landed")
    cf = load_codeframe(a.codeframe)
    roles = load_roles(a.roles)
    personas = {p["archetype_id"]: p for p in
                csv.DictReader(open(os.path.join(landed, "dim_archetype.csv"), encoding="utf-8"))}
    docs = build_corpus(landed)
    if not docs:
        L.die("empty corpus -- run tools/02_land.py first")

    # ---- pass 2: codeframe --------------------------------------------------
    coded_rows = []
    for d in docs:
        d["roles"] = roles_for(d["field"], roles)
        d["is_null_response"] = bool(NULL_RESPONSE.match(d["text"]))
        hits = [] if d["is_null_response"] else code_text(d["text"], cf)
        d["themes"] = [h[0] for h in hits]
        for tid, pol, pat in hits:
            coded_rows.append(dict(
                doc_id=d["doc_id"], archetype_id=d["archetype_id"], panel=d["panel"],
                source=d["source"], field=d["field"], q_position=d["q_position"],
                roles="|".join(d["roles"]), theme_id=tid, theme_polarity=pol,
                matched_pattern=pat, n_chars=d["n_chars"], text=d["text"][:400]))

    # ---- incidence per persona, scoped by role and cut ----------------------
    # Base is personas who ANSWERED a question in the role, never all personas:
    # only 25 personas were asked the K3 instrument, and only those who found
    # something scary were meant to reach the scary probe.
    universe, mentioned, nulls = {}, {}, {}
    for d in docs:
        if d["source"] != "verbatim":
            continue                      # aat prose is house-style summary, not respondent voice
        p = personas.get(d["archetype_id"])
        if not p:
            continue
        for role in d["roles"]:
            for cut, val in L.banner_cuts(p):
                universe.setdefault((role, cut, val), set()).add(d["archetype_id"])
                if d["is_null_response"]:
                    nulls.setdefault((role, cut, val), set()).add(d["archetype_id"])
                for tid in d["themes"]:
                    mentioned.setdefault((role, cut, val, tid), set()).add(d["archetype_id"])

    theme_by_cut = []
    for (role, cut, val), base_ids in sorted(universe.items()):
        n = len(base_ids)
        for t in cf["themes"]:
            k = len(mentioned.get((role, cut, val, t["id"]), ()))
            lo, hi = L.wilson(k, n)
            theme_by_cut.append(dict(
                role=role, cut=cut, cut_value=val,
                null_response_pct=L.pct(len(nulls.get((role, cut, val), ())), n),
                theme_id=t["id"], theme_label=t["label"],
                theme_polarity=t["polarity"], base=n, personas_mentioning=k,
                pct=L.pct(k, n), wilson_low=round(100 * lo, 1), wilson_high=round(100 * hi, 1),
                base_flag=("" if n >= a.min_base else f"BASE<{a.min_base} -- report counts, not %")))

    # per-question detail, so any role number can be opened up
    q_universe, q_mentioned = {}, {}
    for d in docs:
        if d["source"] != "verbatim":
            continue
        key = (d["panel"], d["field"], d["question_text"][:90])
        q_universe.setdefault(key, set()).add(d["archetype_id"])
        for tid in d["themes"]:
            q_mentioned.setdefault(key + (tid,), set()).add(d["archetype_id"])
    theme_by_question = []
    for key, base_ids in sorted(q_universe.items()):
        n = len(base_ids)
        for t in cf["themes"]:
            k = len(q_mentioned.get(key + (t["id"],), ()))
            if not k:
                continue
            lo, hi = L.wilson(k, n)
            theme_by_question.append(dict(
                panel=key[0], meta=key[1], question_text=key[2], theme_id=t["id"],
                theme_polarity=t["polarity"], base=n, personas_mentioning=k, pct=L.pct(k, n),
                wilson_low=round(100 * lo, 1), wilson_high=round(100 * hi, 1)))

    # ---- pass 3: emergent clusters, no codeframe ---------------------------
    # Cluster the open-end verbatims only. The aat prose is model-written summary
    # text with a house style; mixing it in clusters on that style instead of on
    # what personas said.
    verbatims = [d for d in docs if d["source"] == "verbatim" and d["n_chars"] >= 25]
    vecs, _ = L.tfidf([d["text"] for d in verbatims])
    assign, centres = L.kmeans(vecs, a.clusters)
    clusters = []
    for ci, centre in enumerate(centres):
        members = [i for i, c in enumerate(assign) if c == ci]
        if not members:
            continue
        members.sort(key=lambda i: -L.cosine(vecs[i], centre))
        covered = sum(1 for i in members if verbatims[i]["themes"])
        theme_mix = {}
        for i in members:
            for tid in verbatims[i]["themes"]:
                theme_mix[tid] = theme_mix.get(tid, 0) + 1
        top_theme = max(theme_mix.items(), key=lambda kv: -kv[1])[0] if theme_mix else ""
        clusters.append(dict(
            cluster=ci, size=len(members), top_terms=", ".join(L.top_terms(centre, 10)),
            codeframe_coverage_pct=L.pct(covered, len(members)),
            dominant_theme=top_theme,
            dominant_theme_share=L.pct(theme_mix.get(top_theme, 0), len(members)) if top_theme else None,
            panels=",".join(sorted({verbatims[i]["panel"] for i in members})),
            top_questions=" | ".join(
                f"{f}" for f, _ in sorted(
                    {(verbatims[i]["field"], 0) for i in members[:40]})[:4]),
            exemplar_1=verbatims[members[0]]["text"][:220],
            exemplar_2=verbatims[members[1]]["text"][:220] if len(members) > 1 else "",
            exemplar_3=verbatims[members[2]]["text"][:220] if len(members) > 2 else ""))
    clusters.sort(key=lambda c: -c["size"])

    # ---- representative quotes per theme -----------------------------------
    quotes = []
    for t in cf["themes"]:
        pool = [d for d in docs if t["id"] in d["themes"] and d["source"] == "verbatim"]
        if not pool:
            continue
        qvecs, _ = L.tfidf([d["text"] for d in pool]) if len(pool) > 2 else ([{}] * len(pool), {})
        centroid = {}
        for v in qvecs:
            for k, w in v.items():
                centroid[k] = centroid.get(k, 0.0) + w
        norm = sum(w * w for w in centroid.values()) ** 0.5 or 1.0
        centroid = {k: w / norm for k, w in centroid.items()}
        pool_sorted = sorted(range(len(pool)), key=lambda i: -L.cosine(qvecs[i], centroid))
        for rank, i in enumerate(pool_sorted[:4], start=1):
            d = pool[i]
            quotes.append(dict(theme_id=t["id"], theme_label=t["label"], rank=rank,
                               panel=d["panel"], field=d["field"], archetype_id=d["archetype_id"],
                               quote=d["text"][:400]))

    # ---- uncoded, for the next codeframe revision --------------------------
    uncoded = [d for d in verbatims if not d["themes"]]
    uncoded_rows = [dict(doc_id=d["doc_id"], panel=d["panel"], field=d["field"],
                         n_chars=d["n_chars"], text=d["text"][:400])
                    for d in sorted(uncoded, key=lambda d: -d["n_chars"])[:200]]

    os.makedirs(a.out, exist_ok=True)
    L.write_csv(os.path.join(a.out, "verbatim_codes.csv"), list(coded_rows[0]), coded_rows)
    L.write_csv(os.path.join(a.out, "theme_by_cut.csv"), list(theme_by_cut[0]), theme_by_cut)
    L.write_csv(os.path.join(a.out, "theme_by_question.csv"), list(theme_by_question[0]), theme_by_question)
    L.write_csv(os.path.join(a.out, "emergent_clusters.csv"), list(clusters[0]), clusters)
    L.write_csv(os.path.join(a.out, "theme_quotes.csv"), list(quotes[0]), quotes)
    if uncoded_rows:
        L.write_csv(os.path.join(a.out, "uncoded_verbatims.csv"), list(uncoded_rows[0]), uncoded_rows)
    emit_bq_semantic(cf, a.out, a.project)

    # ---- report -------------------------------------------------------------
    print(L.banner("ABR-HTR stage 4 -- semantics and themes"))
    print(f"  corpus: {len(docs):,} documents "
          f"({sum(1 for d in docs if d['source'] == 'verbatim'):,} verbatims, "
          f"{sum(1 for d in docs if d['source'] == 'aat_prose'):,} aat prose fields)")
    print(f"  stage directions stripped from {sum(1 for d in docs if d['n_stage_directions']):,} documents "
          f"({sum(d['n_stage_directions'] for d in docs):,} directions total)")
    print(f"  codeframe: {len(cf['themes'])} themes, {len(coded_rows):,} codings, "
          f"{L.pct(len(verbatims) - len(uncoded), len(verbatims))}% of verbatims coded")
    for role in ("first_reaction", "likes", "dislikes", "scary_probe"):
        rows = [r for r in theme_by_cut if r["role"] == role and r["cut"] == "total" and r["personas_mentioning"]]
        if not rows:
            continue
        base = rows[0]["base"]
        print(f"\n  {role.upper()} -- theme incidence among the {base} personas who answered "
              f"a {role} question (null responses: {rows[0]['null_response_pct']}%):")
        for r in sorted(rows, key=lambda r: -(r["pct"] or 0))[:10]:
            bar = "#" * int((r["pct"] or 0) / 3)
            print(f"    {r['theme_id']:<16} {r['pct']:>5.1f}%  [{r['wilson_low']:>4.1f}-{r['wilson_high']:>5.1f}] "
                  f"{r['personas_mentioning']:>4}/{r['base']:<4} {r['theme_polarity']:<8} {bar}")
    print("\n  DISLIKES by panel (%, personas raising the theme when asked what they did not like):")
    idx = {(r["theme_id"], r["cut_value"]): r for r in theme_by_cut
           if r["role"] == "dislikes" and r["cut"] == "panel"}
    panels = sorted({v for _, v in idx})
    ids = sorted({t for t, _ in idx})
    print(f"    {'theme':<16}" + "".join(f"{p:>11}" for p in panels))
    for tid in ids:
        cells = [idx.get((tid, p)) for p in panels]
        if not any(c and c["personas_mentioning"] for c in cells):
            continue
        line = f"    {tid:<16}"
        for c in cells:
            line += f"{(c['pct'] if c else 0):>9.1f}% " if c else f"{'-':>11}"
        print(line)
    print(f"\n  emergent clusters (k={a.clusters}), largest first -- coverage = share the codeframe already catches:")
    for c in clusters:
        gap = "  <-- CODEFRAME GAP" if (c["codeframe_coverage_pct"] or 0) < 60 else ""
        print(f"    #{c['cluster']:<2} n={c['size']:<4} coverage={c['codeframe_coverage_pct']:>5.1f}% "
              f"[{c['panels']}] {c['top_terms'][:78]}{gap}")
    print(f"\n  wrote verbatim_codes.csv ({len(coded_rows):,}), theme_by_cut.csv ({len(theme_by_cut):,}), "
          f"theme_by_question.csv ({len(theme_by_question):,}), emergent_clusters.csv, "
          f"theme_quotes.csv, uncoded_verbatims.csv ({len(uncoded)} uncoded)")


def emit_bq_semantic(cf, out_dir, project):
    """The same codeframe, as an in-warehouse AI pass.

    Running the deterministic pass first is not a substitute for this -- it is
    how you make this one cheap and checkable. You already know what the answer
    should look like before you spend a single AI call.
    """
    d = os.path.join(out_dir, "load")
    os.makedirs(d, exist_ok=True)
    theme_list = "\n".join(f"  - {t['id']}: {t['label']} ({t['polarity']})" for t in cf["themes"])
    sql = f"""-- Stage 4a: AI verbatim coding against the SAME codeframe as
-- conf/codeframe.json. Run tools/04_semantic_themes.py first and compare: the
-- deterministic pass gives you an expected incidence per theme, so a model
-- result that disagrees wildly is a prompt bug, not a finding.
--
-- Cost control: run with the LIMIT 20 below first and read the output. This is
-- the one place where a wrong prompt costs real money and, worse, silently
-- wrong codes.

CREATE OR REPLACE TABLE `{project}.htr_40_semantic.ai_verbatim_code` AS
SELECT * FROM AI.GENERATE_TABLE(
  MODEL `{project}.htr_40_semantic.gemini_flash`,
  (
    SELECT
      doc_id, archetype_id, panel, meta, qual_clean,
      CONCAT(
        'Code this response from a film-trailer concept test against the codeframe. ',
        'Apply every theme that genuinely appears; apply none if none do. ',
        'Judge only what the respondent said, not what you would expect them to say.\\n\\n',
        'Codeframe:\\n{theme_list}\\n\\n',
        'Question: ', question_text, '\\n',
        'Response: ', qual_clean
      ) AS prompt
    FROM `{project}.htr_20_curated.v_verbatim`
    WHERE qual_clean IS NOT NULL AND LENGTH(qual_clean) >= 25
    -- LIMIT 20   -- uncomment for the first pass
  ),
  STRUCT(
    'themes ARRAY<STRING>, sentiment STRING, is_actionable BOOL, evidence_span STRING'
      AS output_schema,
    0.0 AS temperature
  )
);

-- Reconcile against the deterministic pass before anyone quotes a number:
--   SELECT theme, ai_pct, deterministic_pct, ai_pct - deterministic_pct AS gap
--   FROM ... ORDER BY ABS(gap) DESC
-- A gap over ~10 points on a common theme means the two are not coding the same
-- construct. Fix that before the marts, not after.
"""
    with open(os.path.join(d, "06_ai_verbatim_coding.sql"), "w", encoding="utf-8") as fh:
        fh.write(sql)

    emb = f"""-- Stage 4b: embeddings + KMEANS for emergent themes, in-warehouse.
-- The local pass (tools/04_semantic_themes.py) does the same thing with TF-IDF
-- and gives you the cluster count and the gap list for free. Use this when you
-- want semantic rather than lexical neighbours, and for VECTOR_SEARCH.
--
-- task_type = 'CLUSTERING' is not the default and it materially changes the
-- space. Do not omit it.

CREATE OR REPLACE TABLE `{project}.htr_40_semantic.verbatim_embedding` AS
SELECT doc_id, archetype_id, panel, meta, qual_clean, ml_generate_embedding_result AS embedding
FROM ML.GENERATE_EMBEDDING(
  MODEL `{project}.htr_40_semantic.text_embedding`,
  (SELECT doc_id, archetype_id, panel, meta, qual_clean AS content, qual_clean
   FROM `{project}.htr_20_curated.v_verbatim`
   WHERE LENGTH(qual_clean) >= 25),
  STRUCT(TRUE AS flatten_json_output, 'CLUSTERING' AS task_type)
);

CREATE OR REPLACE MODEL `{project}.htr_40_semantic.verbatim_clusters`
OPTIONS (model_type = 'KMEANS', num_clusters = 12, standardize_features = TRUE) AS
SELECT embedding FROM `{project}.htr_40_semantic.verbatim_embedding`;

-- Label each centroid from its own members rather than from the term list:
CREATE OR REPLACE TABLE `{project}.htr_40_semantic.cluster_labels` AS
WITH members AS (
  SELECT CENTROID_ID, qual_clean,
         ROW_NUMBER() OVER (PARTITION BY CENTROID_ID ORDER BY NEAREST_CENTROIDS_DISTANCE[OFFSET(0)].DISTANCE) AS rn
  FROM ML.PREDICT(MODEL `{project}.htr_40_semantic.verbatim_clusters`,
                  TABLE `{project}.htr_40_semantic.verbatim_embedding`)
)
SELECT CENTROID_ID,
       AI.GENERATE(
         CONCAT('These are the responses closest to one cluster centre in a trailer test. ',
                'Name the single theme they share, in at most six words. Responses:\\n',
                STRING_AGG(qual_clean, '\\n' ORDER BY rn LIMIT 15)),
         connection_id => 'us.vertex',
         endpoint => 'gemini-2.0-flash'
       ).result AS cluster_label,
       COUNT(*) AS n
FROM members
GROUP BY CENTROID_ID;

-- Evidence quotes for a deck, without grepping:
--   SELECT base.qual_clean, distance
--   FROM VECTOR_SEARCH(
--     TABLE `{project}.htr_40_semantic.verbatim_embedding`, 'embedding',
--     (SELECT ml_generate_embedding_result AS embedding FROM ML.GENERATE_EMBEDDING(
--        MODEL `{project}.htr_40_semantic.text_embedding`,
--        (SELECT 'the music and yelling were too loud' AS content),
--        STRUCT(TRUE AS flatten_json_output, 'RETRIEVAL_QUERY' AS task_type))),
--     top_k => 10);
"""
    with open(os.path.join(d, "07_embeddings_clusters.sql"), "w", encoding="utf-8") as fh:
        fh.write(emb)


if __name__ == "__main__":
    main()
