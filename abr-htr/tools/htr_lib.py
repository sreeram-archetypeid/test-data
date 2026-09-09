"""Shared primitives for the ABR-HTR wave (42p.0.0-ABR-HTR-09-01-1).

Stdlib only, on purpose: the ABR container has no pandas/numpy, and every step
here has to be runnable on any machine that has python3 and the CSVs.

Nothing in this module reads or writes files outside what it is handed, and
nothing normalises a source value in place -- derived values always get a new
name. That rule is inherited from the Fatal Fury / ABR-TSR pipelines and it is
what makes a bad parse recoverable.
"""
from __future__ import annotations

import csv
import hashlib
import os
import math
import re
import sys
import unicodedata
from collections import Counter, defaultdict

csv.field_size_limit(1 << 30)

# --- the export's fixed shape ------------------------------------------------

CHANNELS = ("question", "meta", "type", "rating_label", "rating", "selected", "qual")

# Q*_type semantics, verified by fill pattern across all three HTR files:
TYPE_OPEN_END = "1"      # qual only
TYPE_SINGLE = "4"        # selected only, one code
TYPE_MULTI = "5"         # selected, pipe-delimited, sometimes + qual probe
CLOSED_TYPES = (TYPE_SINGLE, TYPE_MULTI)

Q_COL = re.compile(r"^Q(\d+)_(" + "|".join(CHANNELS) + r")$")


def read_csv(path):
    """Return (fieldnames, list-of-dicts). Handles quoted newlines and BOM."""
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rdr = csv.DictReader(fh)
        return rdr.fieldnames, list(rdr)


def write_csv(path, fieldnames, rows):
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fieldnames, extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)
    return path


def question_positions(fieldnames):
    """Ordered Q positions present in a header. Positional, NOT a question id."""
    return sorted({int(m.group(1)) for c in fieldnames if (m := Q_COL.match(c))})


def attribute_columns(fieldnames):
    """Non-question columns, split into persona attributes and the aat block."""
    plain = [c for c in fieldnames if not Q_COL.match(c)]
    return ([c for c in plain if not c.startswith("aat_")],
            [c for c in plain if c.startswith("aat_")])


def cell(row, pos, channel):
    return (row.get(f"Q{pos}_{channel}") or "").strip()


def modal(rows, pos, channel):
    """The modal value of a question-level channel, plus how many variants exist.

    Question text/meta/type are repeated on every row; a variant count above 1
    is a data-quality finding, not something to average away.
    """
    c = Counter(cell(r, pos, channel) for r in rows)
    if not c:
        return "", 0
    return c.most_common(1)[0][0], len(c)


# --- option parsing ----------------------------------------------------------

# "1. I liked it a lot!"                      -> code 1
# "1. 1. Increases my interest"               -> code 1 (doubled prefix, FF D2)
# "2. 4 - To a great extent"                  -> code 2, printed scale point 4
_CODE = re.compile(r"^\s*(\d+)\s*\.\s*(?:(\d+)\s*\.\s*)?(.*)$", re.S)
_PRINTED = re.compile(r"^\s*(\d+)\s*[-‐-―:)]\s*(.+)$", re.S)


def split_option(value):
    """('2. 4 - To a great extent') -> (code=2, printed=4, label='To a great extent').

    ``code`` is the export's option code. ``printed`` is a scale number printed
    inside the label itself -- the two exist independently in this data and they
    do not always agree or even run in the same direction, so both are kept.
    """
    raw = (value or "").strip()
    if not raw:
        return None, None, ""
    m = _CODE.match(raw)
    if not m:
        return None, None, raw
    code = int(m.group(1))
    rest = (m.group(3) or "").strip()
    printed = None
    pm = _PRINTED.match(rest)
    if pm:
        printed, rest = int(pm.group(1)), pm.group(2).strip()
    return code, printed, rest


def split_multi(value):
    """Multi-selects are pipe-delimited in every HTR file."""
    return [p.strip() for p in (value or "").split("|") if p.strip()]


# --- text normalisation ------------------------------------------------------

_WS = re.compile(r"\s+")
_PUNCT_TAIL = re.compile(r"[\s.!?,;:]+$")


def norm_text(s):
    """Grouping key: NFKC, straight quotes, collapsed space, no trailing punct.

    Use for keys and joins only. Never write this back over a source column --
    option labels in this study differ by punctuation alone (N9) and that drift
    is itself evidence.
    """
    s = unicodedata.normalize("NFKC", s or "")
    s = (s.replace("’", "'").replace("‘", "'")
          .replace("“", '"').replace("”", '"')
          .replace("–", "-").replace("—", "-").replace("―", "-"))
    s = _WS.sub(" ", s).strip()
    return _PUNCT_TAIL.sub("", s).casefold()


def slug(s, maxlen=60):
    s = norm_text(s)
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s[:maxlen] or "x"


def qkey(panel, meta, question_text):
    """Stable question identity. Q-position is positional and must never be it."""
    h = hashlib.sha1(f"{panel}|{norm_text(meta)}|{norm_text(question_text)}".encode()).hexdigest()[:10]
    return f"{panel}_{slug(meta, 20)}_{h}"


# --- persona attribute normalisation ----------------------------------------

def norm_gender(raw):
    v = norm_text(raw)
    if v.startswith("m"):
        return "Male"
    if v.startswith("f"):
        return "Female"
    return None


AGE_BANDS = ((4, 6, "4-6"), (7, 9, "7-9"), (10, 12, "10-12"), (13, 17, "13-17"),
             (18, 24, "18-24"), (25, 34, "25-34"), (35, 44, "35-44"),
             (45, 54, "45-54"), (55, 64, "55-64"), (65, 120, "65+"))


def age_band(age):
    for lo, hi, name in AGE_BANDS:
        if lo <= age <= hi:
            return name
    return None


def parse_age(raw):
    """-> (age_exact|None, band|None, is_imputed).

    HTR age arrives as a bare age ('9'), prose ('9 years old'), a clean bucket
    ('25-44'), or a bucket that straddles two banner bands ('18-27'). A straddle
    is midpointed and flagged; it is never silently assigned.
    """
    v = norm_text(raw)
    if not v:
        return None, None, False
    m = re.fullmatch(r"(\d{1,3})(?:\s*years?\s*old)?", v)
    if m:
        a = int(m.group(1))
        return a, age_band(a), False
    m = re.fullmatch(r"(\d{1,3})\s*-\s*(\d{1,3})", v)
    if m:
        lo, hi = int(m.group(1)), int(m.group(2))
        band_lo, band_hi = age_band(lo), age_band(hi)
        if band_lo and band_lo == band_hi:
            return None, band_lo, False
        mid = (lo + hi) // 2
        return None, age_band(mid), True          # straddles bands -> imputed
    m = re.match(r"(\d{1,3})\s*\(", v)            # '21 (17-24)'
    if m:
        a = int(m.group(1))
        return a, age_band(a), False
    return None, None, False


_MONEY = re.compile(r"\$\s*([\d,]+)")


def parse_income(raw):
    """-> (low_usd|None, high_usd|None, flags). HTR income is free text (N11)."""
    v = raw or ""
    nums = [int(x.replace(",", "")) for x in _MONEY.findall(v)]
    flags = []
    low = norm_text(v)
    if "household" in low:
        flags.append("household")
    if "dependent" in low:
        flags.append("dependent")
    if "varies" in low or not nums:
        flags.append("unparsed")
    if len(nums) >= 2:
        return min(nums), max(nums), flags
    if len(nums) == 1:
        return nums[0], nums[0], flags
    return None, None, flags


def to_int(raw):
    v = norm_text(raw)
    return int(v) if re.fullmatch(r"-?\d+", v) else None


# --- verbatim hygiene --------------------------------------------------------

_STAGE = re.compile(r"\[[^\[\]]{2,80}\]|\*[^*\n]{2,80}\*")
_HARNESS = ("mixtureofexperts", "residualrisks", "selfcritique", "expertiq")


def strip_stage_directions(text):
    """-> (clean_text, n_directions, directions).

    94-98% of ABR-TSR open ends carried roleplay stage directions; 27-93% of
    HTR's do. Left in, they dominate any vector space -- every '[hides face in
    my shirt]' pulls harder than the sentence around it. Stripped, the count is
    itself a usable embodiment/engagement signal, so it is returned, not thrown.
    """
    found = _STAGE.findall(text or "")
    clean = _WS.sub(" ", _STAGE.sub(" ", text or "")).strip()
    return clean, len(found), found


def is_harness_leak(text):
    """Generation-harness JSON that leaked into a data cell (ABR-TSR N3)."""
    t = (text or "").lstrip()
    if t.startswith("{") and len(t) > 400:
        return True
    low = norm_text(text).replace(" ", "")
    return any(k in low for k in _HARNESS)


# --- statistics --------------------------------------------------------------

def wilson(k, n, z=1.96):
    """Wilson score interval. Normal-approximation CIs are wrong at n=25 and
    wrong again near a 95% ceiling, and HTR has headline numbers at both."""
    if not n:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / d
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, centre - half), min(1.0, centre + half))


def spearman(xs, ys):
    """Rank correlation, average ranks for ties. None if fewer than 3 pairs."""
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    if len(pairs) < 3:
        return None

    def ranks(vals):
        order = sorted(range(len(vals)), key=lambda i: vals[i])
        out = [0.0] * len(vals)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and vals[order[j + 1]] == vals[order[i]]:
                j += 1
            avg = (i + j) / 2 + 1
            for k in range(i, j + 1):
                out[order[k]] = avg
            i = j + 1
        return out

    rx, ry = ranks([p[0] for p in pairs]), ranks([p[1] for p in pairs])
    n = len(pairs)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    den = math.sqrt(sum((a - mx) ** 2 for a in rx) * sum((b - my) ** 2 for b in ry))
    return num / den if den else None


def pct(k, n, digits=1):
    return round(100.0 * k / n, digits) if n else None


# --- tiny text-vector toolkit (TF-IDF + spherical k-means) -------------------

STOPWORDS = set("""a about above after again against all am an and any are aren't as at be because been
before being below between both but by can cannot could couldn't did didn't do does doesn't doing don't down
during each few for from further had hadn't has hasn't have haven't having he he'd he'll he's her here here's
hers herself him himself his how how's i i'd i'll i'm i've if in into is isn't it it's its itself let's me more
most mustn't my myself no nor not of off on once only or other ought our ours ourselves out over own same shan't
she she'd she'll she's should shouldn't so some such than that that's the their theirs them themselves then there
there's these they they'd they'll they're they've this those through to too under until up very was wasn't we
we'd we'll we're we've were weren't what what's when when's where where's which while who who's whom why why's
with won't would wouldn't you you'd you'll you're you've your yours yourself yourselves just really think thing
things get got like really kind sort lot bit also would maybe much many one two three
""".split())

_WORD = re.compile(r"[a-z][a-z'\-]{1,}")


def tokenize(text, keep_stopwords=False):
    toks = _WORD.findall(norm_text(text))
    if keep_stopwords:
        return toks
    return [t for t in toks if t not in STOPWORDS and len(t) > 2]


def tfidf(docs, min_df=2, max_df_ratio=0.6, bigrams=True):
    """-> (vectors as {term: weight} L2-normalised, idf dict)."""
    tokenised = []
    for d in docs:
        toks = tokenize(d)
        if bigrams:
            toks = toks + [f"{a}_{b}" for a, b in zip(toks, toks[1:])]
        tokenised.append(toks)
    df = Counter()
    for toks in tokenised:
        df.update(set(toks))
    n = len(docs)
    keep = {t for t, c in df.items() if c >= min_df and c <= max_df_ratio * n}
    idf = {t: math.log((1 + n) / (1 + df[t])) + 1.0 for t in keep}
    vecs = []
    for toks in tokenised:
        tf = Counter(t for t in toks if t in keep)
        v = {t: (1 + math.log(c)) * idf[t] for t, c in tf.items()}
        norm = math.sqrt(sum(w * w for w in v.values())) or 1.0
        vecs.append({t: w / norm for t, w in v.items()})
    return vecs, idf


def cosine(a, b):
    if len(a) > len(b):
        a, b = b, a
    return sum(w * b.get(t, 0.0) for t, w in a.items())


def kmeans(vecs, k, iters=30, seed=17):
    """Spherical k-means on L2-normalised sparse vectors. Deterministic:
    k-means++ style seeding driven by a fixed-seed LCG, no random module."""
    n = len(vecs)
    if n == 0 or k < 1:
        return [], []
    k = min(k, n)
    state = seed

    def rnd():
        nonlocal state
        state = (1103515245 * state + 12345) % (1 << 31)
        return state / (1 << 31)

    centres = [dict(vecs[int(rnd() * n) % n])]
    while len(centres) < k:
        d2 = [min((1 - cosine(v, c)) ** 2 for c in centres) for v in vecs]
        tot = sum(d2) or 1.0
        target, acc = rnd() * tot, 0.0
        pick = n - 1
        for i, d in enumerate(d2):
            acc += d
            if acc >= target:
                pick = i
                break
        centres.append(dict(vecs[pick]))

    assign = [0] * n
    for _ in range(iters):
        moved = False
        for i, v in enumerate(vecs):
            best, bi = -1.0, 0
            for ci, c in enumerate(centres):
                s = cosine(v, c)
                if s > best:
                    best, bi = s, ci
            if assign[i] != bi:
                assign[i], moved = bi, True
        sums = [defaultdict(float) for _ in range(len(centres))]
        counts = [0] * len(centres)
        for i, v in enumerate(vecs):
            counts[assign[i]] += 1
            for t, w in v.items():
                sums[assign[i]][t] += w
        for ci in range(len(centres)):
            if not counts[ci]:
                continue
            norm = math.sqrt(sum(w * w for w in sums[ci].values())) or 1.0
            centres[ci] = {t: w / norm for t, w in sums[ci].items()}
        if not moved:
            break
    return assign, centres


def top_terms(centre, limit=8):
    return [t.replace("_", " ") for t, _ in sorted(centre.items(), key=lambda kv: -kv[1])[:limit]]


# --- export identity: study / instrument / panel / build / run ---------------

# Two naming conventions in play, both of which already carry a version:
#   42p.0.0-ABR-HTR-K9-09-01-1 — Results.csv   build 42p.0.0, HTR, K9, 09-01, run 1
#   ABR-TSR_RETURN_v4_K_T1 — Results.csv       build v4,      TSR, T1
_NAME_BUILD_FIRST = re.compile(
    r"^(?P<build>\d+[a-z]*(?:\.\d+)*)-(?P<study>[A-Z]+)-(?P<instrument>[A-Z]+)"
    r"(?:-(?P<panel>K\d+|T\d+|[A-Z]{1,3}\d*))?"
    r"(?:-(?P<date>\d{2}-\d{2}))?(?:-(?P<run>\d+))?", re.I)
_NAME_STUDY_FIRST = re.compile(
    r"^(?P<study>[A-Z]+)-(?P<instrument>[A-Z]+)(?:_[A-Z]+)*_(?P<build>v\d+[a-z]*)"
    r"(?:_(?P<group>[A-Z]))?(?:_(?P<panel>T\d+|K\d+))?", re.I)


def parse_export_name(filename):
    """Pull (study, instrument, panel, build, export_date, run_seq) out of a filename.

    Version lives in the filename in this study and nowhere else in the data, so
    this is the only place it can come from. Returns None for anything that does
    not look like an export, so a stray file in the folder is skipped rather
    than landed as a mystery run.
    """
    stem = re.sub(r"\s*[-—–]\s*Results.*$", "", os.path.basename(filename))
    stem = re.sub(r"\.csv$", "", stem, flags=re.I).strip()
    for rx in (_NAME_BUILD_FIRST, _NAME_STUDY_FIRST):
        m = rx.match(stem)
        if m:
            g = m.groupdict()
            panel = (g.get("panel") or "").upper() or None
            return dict(
                study=(g.get("study") or "").upper(),
                instrument=(g.get("instrument") or "").upper(),
                panel=panel,
                build=g.get("build") or "",
                export_date=g.get("date") or "",
                run_seq=int(g["run"]) if g.get("run") else 1,
                stem=stem)
    return None


def run_id(meta):
    """Stable identity for one export = one run. Facts from two runs coexist;
    nothing is ever deduplicated across runs, because the difference between
    two runs of the same instrument IS the measurement."""
    parts = [meta["instrument"], meta["panel"] or "MAIN", meta["build"]]
    if meta.get("export_date"):
        parts.append(meta["export_date"])
    if meta.get("run_seq", 1) != 1:
        parts.append(f"r{meta['run_seq']}")
    return slug("_".join(parts), 60)


def panel_code(meta):
    """Panel label that is stable ACROSS versions, so the same question in two
    builds gets the same question_key and can be compared. Deliberately does not
    include build, date or run."""
    return f"{meta['instrument']}_{meta['panel'] or 'MAIN'}"


# --- banner cuts -------------------------------------------------------------

def banner_cuts(persona):
    """Cuts available on this wave, as (cut_name, cut_value) pairs.

    Deliberately short. The kids panels cannot carry a demographic banner --
    K3 is n=25 in total and its largest group is 19 -- so the adult panel
    carries the cuts and the kids panels are read as counts.
    """
    out = [("total", "total")]
    if persona.get("panel"):
        out.append(("panel", persona["panel"]))
    if persona.get("gender_norm"):
        out.append(("gender", persona["gender_norm"]))
    if persona.get("age_band"):
        out.append(("age_band", persona["age_band"]))
    if persona.get("group_code"):
        out.append(("group", persona["group_code"]))
    adopt = (persona.get("archetype_adoption_category_name") or "").strip()
    if adopt:
        out.append(("adoption", re.sub(r"s$", "", adopt)))     # Innovators -> Innovator
    return out


# --- misc --------------------------------------------------------------------

def die(msg, code=2):
    print(f"FAIL: {msg}", file=sys.stderr)
    raise SystemExit(code)


def banner(title, ch="="):
    return f"\n{ch * 92}\n{title}\n{ch * 92}"
