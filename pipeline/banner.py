"""
Stage 7: the tidy banner table, and stage 8: render to xlsx in the W-Tabs layout.

Cuts and metrics are driven entirely by the Gate 1 config. The renderer is
template-driven -- it reads a layout spec rather than hardcoding cell positions.
"""
import re, statistics
from collections import defaultdict, OrderedDict

AGE_RX = re.compile(r"(\d+)")


def norm_age_band(raw, bands):
    """Map a messy age value onto the configured banner bands."""
    if not raw:
        return None
    raw = raw.strip()
    for b in bands:                                  # already a clean band
        if raw == b:
            return b
    nums = [int(n) for n in AGE_RX.findall(raw)]
    if not nums:
        return None
    age = nums[0]
    for b in bands:
        parts = AGE_RX.findall(b)
        if len(parts) == 2 and int(parts[0]) <= age <= int(parts[1]):
            return b
    return None


def norm_plain(raw, _=None):
    return raw.strip().title() if raw and raw.strip() else None


NORMALIZERS = {"age_band": norm_age_band, "titlecase": norm_plain, "raw": norm_plain}


def resolve_cuts(respondents, clean_rows, gate1, sentinel_min):
    """
    Build, per respondent, the set of (cut_name, cut_value) they belong to.
    Two families: attribute cuts read the person; behaviour cuts read answers.
    """
    from build import primary_code

    member = defaultdict(list)
    for key, person in respondents.items():
        rid = key[0]
        member[rid].append(("TOTAL", "Total"))
        for cut in gate1["banner_cuts"]:
            if cut["kind"] != "attribute":
                continue
            raw = person.get(cut["column"], "")
            fn = NORMALIZERS[cut.get("normalize", "raw")]
            val = fn(raw, cut.get("bands")) if cut.get("normalize") == "age_band" \
                else fn(raw)
            if val:
                member[rid].append((cut["name"], val))

    # behaviour cuts: "top-box on the question whose code matches X"
    beh = [c for c in gate1["banner_cuts"] if c["kind"] == "behaviour"]
    if beh:
        flags = defaultdict(set)
        for r in clean_rows:
            if not r.get("is_primary"):
                continue
            pc = primary_code(r["selections"], sentinel_min)
            if pc is None:
                continue
            for cut in beh:
                if r["question_code"] != cut["question_code"]:
                    continue
                if cut.get("text_contains") and \
                        cut["text_contains"].lower() not in r["question_text"].lower():
                    continue
                if pc <= cut.get("top_n", 1):
                    flags[r["respondent_id"]].add((cut["name"], cut["label"]))
        for rid, fs in flags.items():
            member[rid].extend(sorted(fs))
    return {rid: sorted(set(v)) for rid, v in member.items()}


def compute_banner(clean_rows, questions, membership, gate1):
    """
    One row per (question, metric, cut_name, cut_value).
    Base is computed PER QUESTION, never once per study -- which is what makes
    a drop where different files carry different questions come out right.
    """
    from build import primary_code

    sentinel_min = gate1.get("sentinel_min_code", 90)
    one_is_best = gate1["scale_direction"] == "1_IS_BEST"
    use_primary_only = gate1.get("dedup_policy", "PRIMARY_ONLY") == "PRIMARY_ONLY"

    buckets = defaultdict(list)
    for r in clean_rows:
        if use_primary_only and not r.get("is_primary"):
            continue
        qkey = (r["question_code"], r["question_text"])
        for cut in membership.get(r["respondent_id"], []):
            buckets[(qkey, cut)].append(r)

    out = []
    for (qkey, cut), rows in buckets.items():
        q = questions[qkey]
        smax = q["scale_max"]
        answered = [r for r in rows
                    if r["selections"] or r["numeric"] is not None or r["verbatim"]]
        n = len(answered)
        if n == 0:
            continue
        rec = {"question_code": qkey[0], "question_text": qkey[1],
               "cut_name": cut[0], "cut_value": cut[1], "n": n}

        rec["tabulation"] = q["tabulation"]

        if q["tabulation"] == "NUMERIC":
            codes = [r["numeric"] for r in answered if r["numeric"] is not None]
        else:
            codes = [primary_code(r["selections"], sentinel_min) for r in answered]
            codes = [c for c in codes if c is not None]

        # Box metrics only where they mean something: an ordered scale with one
        # answer per respondent. A pick-list has no bottom box.
        if q["tabulation"] in ("SCALE", "NUMERIC") and smax and smax >= 2 and codes:
            if one_is_best:
                tb = sum(1 for c in codes if c == 1)
                t2b = sum(1 for c in codes if c <= 2)
                bot = sum(1 for c in codes if c == smax)
                b2b = sum(1 for c in codes if c >= smax - 1)
            else:
                tb = sum(1 for c in codes if c == smax)
                t2b = sum(1 for c in codes if c >= smax - 1)
                bot = sum(1 for c in codes if c == 1)
                b2b = sum(1 for c in codes if c <= 2)
            base = len(codes)
            rec.update({
                "TB": tb / base, "T2B": t2b / base,
                "B2B": b2b / base, "BOT": bot / base,
                "MEAN": statistics.mean(codes),
                "scale_max": smax,
            })
        # per-option percentages (works for single and multi select alike)
        opt_counts = Counter_like(answered, sentinel_min)
        rec["options"] = {code: cnt / n for code, cnt in opt_counts.items()}
        rec["option_labels"] = {c: l for c, l in q["options"]}
        rec["n_verbatims"] = sum(1 for r in answered if r["verbatim"])
        out.append(rec)
    return out


def Counter_like(rows, sentinel_min):
    """% of respondents selecting each option. Multi-select can exceed 100%."""
    counts = defaultdict(int)
    for r in rows:
        seen = set()
        for s in r["selections"]:
            if s["code"] is not None and s["code"] not in seen:
                counts[s["code"]] += 1
                seen.add(s["code"])
    return counts
