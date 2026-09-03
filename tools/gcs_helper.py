#!/usr/bin/env python3
"""
Minimal GCS transport over the JSON API, using only the standard library.

Why this exists: `gcloud` cannot be installed in the web sandbox --
dl.google.com is blocked by network policy -- and `google-cloud-storage` is not
present in a fresh container either. tools/slugify_upload.sh is built around
`gcloud storage cp`, so without a fallback the staging step cannot run at all
from here, which is how the two section-1.4 files ended up unlanded.

This is deliberately NOT a general client. It does the three things the staging
step needs and nothing else, so there is no dependency to install and no version
to pin:

    python3 tools/gcs_helper.py ls                        # object names, one per line
    python3 tools/gcs_helper.py cp <local> <object-name>  # upload one object
    python3 tools/gcs_helper.py size <object-name>        # bytes, for verification

Credentials come from $GOOGLE_ACCESS_TOKEN. Never from a file in the repo, and
never written to one: the token is short-lived and a committed credential
outlives its usefulness by years.

GCS_PREFIX comes from config.env (gitignored), so the bucket name stays out of
the committed source exactly as the SQL keeps ${PROJECT_ID} out of it.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://storage.googleapis.com/storage/v1"
UPLOAD = "https://storage.googleapis.com/upload/storage/v1"


def config(key):
    """
    Read KEY from config.env, with env vars winning.

    config.env is shell, and its values reference each other
    (`GCS_PREFIX=${BUCKET}/arena-ff/read/v1`), so a line-by-line read returns a
    literal '${BUCKET}/...' and fails downstream with a confusing message. Parse
    every key first, then expand references until they settle.
    """
    vals = {}
    try:
        with open("config.env", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$", line)
                if m:
                    vals[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    vals.update({k: v for k, v in os.environ.items() if k in vals or k == key})

    ref = re.compile(r"\$\{?([A-Z_][A-Z0-9_]*)\}?")
    for _ in range(10):                       # bounded: no infinite loop on a cycle
        changed = False
        for k, v in vals.items():
            nv = ref.sub(lambda m: vals.get(m.group(1), m.group(0)), v)
            if nv != v:
                vals[k], changed = nv, True
        if not changed:
            break

    if key not in vals:
        sys.exit(f"ERROR: {key} is unset and not found in ./config.env")
    return vals[key]


def token():
    t = os.environ.get("GOOGLE_ACCESS_TOKEN", "").strip()
    if not t:
        sys.exit(
            "ERROR: GOOGLE_ACCESS_TOKEN is unset.\n"
            "       export it first; it is short-lived and never stored."
        )
    return t


def split_prefix():
    """gs://bucket/a/b/c -> ('bucket', 'a/b/c')"""
    p = config("GCS_PREFIX")
    if not p.startswith("gs://"):
        sys.exit(f"ERROR: GCS_PREFIX must start with gs:// (got {p!r})")
    bucket, _, prefix = p[5:].partition("/")
    return bucket, prefix.rstrip("/")


def call(url, data=None, headers=None, method=None):
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token()}")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            body = r.read()
            return json.loads(body) if body else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:400]
        # 401 is overwhelmingly an expired token, and the raw message does not
        # say so. Saying it here saves rediscovering it every session.
        hint = "\n       The access token has most likely expired." if e.code == 401 else ""
        sys.exit(f"ERROR: HTTP {e.code} from {url.split('?')[0]}\n       {detail}{hint}")


def objects():
    bucket, prefix = split_prefix()
    out, page = [], None
    while True:
        q = {"prefix": prefix + "/", "fields": "items(name,size),nextPageToken"}
        if page:
            q["pageToken"] = page
        d = call(f"{API}/b/{bucket}/o?" + urllib.parse.urlencode(q))
        out += [(o["name"].rsplit("/", 1)[-1], int(o["size"])) for o in d.get("items", [])]
        page = d.get("nextPageToken")
        if not page:
            return sorted(out)


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    cmd = args[0]

    if cmd == "ls":
        for name, _ in objects():
            print(name)

    elif cmd == "size":
        want = args[1]
        for name, size in objects():
            if name == want:
                print(size)
                return
        sys.exit(f"ERROR: no such object: {want}")

    elif cmd == "cp":
        local, obj = args[1], args[2]
        bucket, prefix = split_prefix()
        blob = f"{prefix}/{obj}"
        with open(local, "rb") as fh:
            body = fh.read()
        q = urllib.parse.urlencode({"uploadType": "media", "name": blob})
        d = call(
            f"{UPLOAD}/b/{bucket}/o?{q}",
            data=body,
            headers={"Content-Type": "text/csv", "Content-Length": str(len(body))},
            method="POST",
        )
        # Verify server-side rather than trusting a 200: a truncated upload
        # returns success and surfaces later as a wrong row count at Gate 1.
        got = int(d.get("size", -1))
        if got != len(body):
            sys.exit(f"ERROR: {obj} uploaded {got} bytes, local file is {len(body)}")
        print(f"  {obj}  {got:,} bytes")

    else:
        sys.exit(f"ERROR: unknown command {cmd!r}")


if __name__ == "__main__":
    main()
