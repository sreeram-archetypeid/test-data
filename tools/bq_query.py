#!/usr/bin/env python3
"""
Run a repo .sql file against BigQuery, using only the standard library.

Every tools/build_*.sh runner shells out to `bq`, which cannot be installed in
the web sandbox (dl.google.com is blocked by network policy), and a fresh
container has no google-cloud-bigquery either. So sql/42 and sql/43 were
executed ad-hoc and never got a runner -- they are still the only SQL files in
the repo that cannot be rebuilt by command. This is the missing piece.

It does the same substitution the shell runners do: the committed SQL carries
${PROJECT_ID} / ${DS_*} / ${GCS_PREFIX} placeholders so no project or bucket
name is ever committed, and they are filled from config.env at execution time.

    python3 tools/bq_query.py --check                  # connectivity + identity
    python3 tools/bq_query.py sql/43_mart_banner_wtab.sql
    python3 tools/bq_query.py -e 'SELECT COUNT(*) FROM ...'
    python3 tools/bq_query.py -e '...' --format tsv    # for piping into a gate

Credentials come from $GOOGLE_ACCESS_TOKEN. Never from a file in the repo, and
never written to one.

Note on DDL: a CREATE OR REPLACE returns no rows, so "0 rows" is success, not an
empty result. The script prints the statement kind so the two cannot be
confused.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://bigquery.googleapis.com/bigquery/v2"


def load_config():
    """
    Parse config.env into a dict, expanding its internal ${VAR} references.

    config.env is shell and its values reference each other, so a line-by-line
    read yields literals like '${BUCKET}/arena-ff/read/v1'.
    """
    vals = {}
    try:
        with open("config.env", encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)=(.*)$", line)
                if m:
                    vals[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    except FileNotFoundError:
        sys.exit("ERROR: ./config.env not found — run from the repo root.")

    for k in list(vals):
        if os.environ.get(k):
            vals[k] = os.environ[k]

    ref = re.compile(r"\$\{?([A-Z_][A-Z0-9_]*)\}?")
    for _ in range(10):                     # bounded, so a cycle cannot hang us
        changed = False
        for k, v in vals.items():
            nv = ref.sub(lambda m: vals.get(m.group(1), m.group(0)), v)
            if nv != v:
                vals[k], changed = nv, True
        if not changed:
            break
    return vals


def token():
    t = os.environ.get("GOOGLE_ACCESS_TOKEN", "").strip()
    if not t:
        sys.exit(
            "ERROR: GOOGLE_ACCESS_TOKEN is unset.\n"
            "       export it first; it is short-lived and never stored."
        )
    return t


def substitute(sql, cfg):
    """Fill ${VAR} from config.env, and refuse to run with any left unresolved."""
    out = re.sub(r"\$\{([A-Z_][A-Z0-9_]*)\}", lambda m: cfg.get(m.group(1), m.group(0)), sql)
    missing = sorted(set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)\}", out)))
    if missing:
        # Running with an unresolved placeholder would create a table literally
        # named '${DS_MART}' — recoverable, but confusing enough to be worth a
        # hard stop.
        sys.exit(f"ERROR: unresolved placeholders (not in config.env): {', '.join(missing)}")
    return out


def query(sql, cfg, timeout_ms=600000):
    body = json.dumps({
        "query": sql,
        "useLegacySql": False,
        "timeoutMs": timeout_ms,
        # DDL and multi-statement scripts need the job to outlive the HTTP call.
        "jobCreationMode": "JOB_CREATION_REQUIRED",
    }).encode()
    req = urllib.request.Request(
        f"{API}/projects/{cfg['PROJECT_ID']}/queries", data=body, method="POST"
    )
    req.add_header("Authorization", f"Bearer {token()}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            d = json.loads(r.read())
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except Exception:
            detail = detail[:600]
        hint = "\n       The access token has most likely expired." if e.code == 401 else ""
        sys.exit(f"ERROR: HTTP {e.code} from BigQuery\n       {detail}{hint}")

    if not d.get("jobComplete"):
        job = d["jobReference"]["jobId"]
        sys.exit(
            f"ERROR: job {job} did not complete within {timeout_ms // 1000}s.\n"
            "       It may still be running — check the BigQuery console before re-running."
        )
    if "errors" in d:
        sys.exit("ERROR: " + "; ".join(e.get("message", "") for e in d["errors"]))
    return d


def render(d, fmt):
    fields = [f["name"] for f in d.get("schema", {}).get("fields", [])]
    rows = [[c.get("v") for c in r.get("f", [])] for r in d.get("rows", [])]
    if not fields:
        return None, rows
    if fmt == "tsv":
        out = ["\t".join(fields)] + ["\t".join("" if v is None else str(v) for v in r) for r in rows]
    else:
        w = [max(len(fields[i]), *(len(str(r[i])) for r in rows)) if rows else len(fields[i])
             for i in range(len(fields))]
        out = ["  ".join(f.ljust(w[i]) for i, f in enumerate(fields)),
               "  ".join("-" * w[i] for i in range(len(fields)))]
        out += ["  ".join(("" if r[i] is None else str(r[i])).ljust(w[i])
                          for i in range(len(fields))) for r in rows]
    return "\n".join(out), rows


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sql_file", nargs="?", help="path to a .sql file in the repo")
    ap.add_argument("-e", "--execute", help="inline SQL instead of a file")
    ap.add_argument("--check", action="store_true", help="connectivity and identity smoke test")
    ap.add_argument("--format", choices=["table", "tsv"], default="table")
    ap.add_argument("--dry-run", action="store_true", help="print resolved SQL, run nothing")
    args = ap.parse_args()

    cfg = load_config()

    if args.check:
        d = query(
            "SELECT SESSION_USER() AS caller, "
            "FORMAT_TIMESTAMP('%F %T UTC', CURRENT_TIMESTAMP()) AS checked_at",
            cfg,
        )
        text, _ = render(d, args.format)
        print(f"project: {cfg['PROJECT_ID']}")
        print(text)
        return

    if args.execute:
        sql, label = substitute(args.execute, cfg), "<inline>"
    elif args.sql_file:
        sql = substitute(open(args.sql_file, encoding="utf-8").read(), cfg)
        label = args.sql_file
    else:
        ap.error("give a .sql file, -e SQL, or --check")

    if args.dry_run:
        print(sql)
        return

    d = query(sql, cfg)
    kind = d.get("statementType", "")

    # Detect "no result set" via totalRows, NOT via the schema and NOT via
    # statementType:
    #
    #   - a CREATE TABLE AS SELECT returns the schema of the table it just
    #     built, with no rows, so keying off the schema prints an empty result
    #     grid for a successful build -- exactly the "0 rows reads like failure"
    #     confusion this is meant to prevent;
    #   - jobs.query does not return statementType at all. That field only comes
    #     back from jobs.get, so a check against it silently never fires.
    #
    # totalRows is absent for DDL and present (even as "0") for a SELECT.
    if d.get("totalRows") is None:
        affected = d.get("numDmlAffectedRows")
        print(f"{label}: {kind or 'DDL'} OK"
              + (f", {int(affected):,} rows affected" if affected else ""))
        return

    text, rows = render(d, args.format)
    if text is None:
        print(f"{label}: {kind or 'statement'} OK")
    else:
        print(text)
        if args.format == "table":
            print(f"\n{len(rows):,} row{'' if len(rows) == 1 else 's'}  ({label})")


if __name__ == "__main__":
    main()
