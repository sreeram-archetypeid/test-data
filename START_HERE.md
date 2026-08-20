# Start Here — BigQuery Migration, Day 1

Companion to `BIGQUERY_MIGRATION_PLAN.md`. That document is the *what and why*
(1,146 lines, execution-ready). This one is the *do this next* — the ordered
path to a green **Gate 1**, which is the point where the migration is genuinely
started and the rest of the plan becomes mechanical.

**Time to Gate 1: about half a day**, and most of it is waiting on GCP
provisioning. Steps 0–2 cost nothing and need no cloud access.

---

## Step 0 — Decisions to make before you touch GCP

Three things are cheap now and expensive later.

| Decision | Recommendation | Why it is hard to reverse |
|---|---|---|
| **Region** | Pick one, e.g. `us-central1` | BQML models and the Vertex connection for Section 10 must live in the *same* region as the data. A cross-region mistake means reloading everything. |
| **Project** | A dedicated project, not a shared sandbox | Section 13 restricts `ff_00_raw` to a pipeline service account. That guarantee is unenforceable in a project where everyone is Editor. |
| **Bucket** | One bucket, same region as the datasets | Cross-region reads from external tables are slow and billable. |

Also worth resolving early, because they change what you build rather than how:
the five open questions in **Appendix A**. None of them block Phase 1 — start
now, ask in parallel. Two matter soon:

- **Q5 (2.1 vs 2.1X)** decides `is_primary_run`, which Phase 2 needs.
- **Q3 (998 vs 398)** decides whether you are missing files. If the answer is
  "CSVs are missing", the Gate 1 targets below change and you want to know
  before, not after.

```bash
export PROJECT=<your-project>
export REGION=us-central1
export BUCKET=gs://<your-bucket>/arena-ff/read/v1
```

---

## Step 1 — Preflight the source data (no cloud, ~10 seconds)

Validate the 12 CSVs locally before spending anything. This reproduces the
Gate 1 and Gate 2 numbers from the source files, so a failure here means the
data changed — not that your pipeline is wrong.

```bash
python3 tools/preflight_check.py
```

Expected output ends with `PREFLIGHT PASSED - safe to stage to GCS.` It verifies:

- 12 CSVs present, headers matching the generated schema for all three families
- the 46 persona-attribute columns identical across every file
- **596 / 398 / 398 = 1,392 rows**, **398 unique personas**
- 8,957 fields containing embedded newlines (this is D1, and it is why
  `--allow_quoted_newlines` is mandatory)

Exit code is non-zero on any failure, so this is safe to wire into CI later.

> The two `.xlsx` files in the source folder are Excel renderings of CSVs
> already in the set. Preflight warns about them. **Do not upload them.**

---

## Step 2 — Confirm the schema generator (no cloud)

Phase 1 of the checklist calls for `tools/gen_raw_schema.py`. It exists now and
is verified against the real headers:

```bash
python3 tools/gen_raw_schema.py 20 | tr ',' '\n' | wc -l   # 186
python3 tools/gen_raw_schema.py 35 | tr ',' '\n' | wc -l   # 291
python3 tools/gen_raw_schema.py 36 | tr ',' '\n' | wc -l   # 298
```

Three output modes:

| Mode | Use |
|---|---|
| *(default)* | `col:STRING,...` for `bq load` |
| `--json` | BigQuery JSON schema file |
| `--external-ddl` | full `CREATE OR REPLACE EXTERNAL TABLE` with every column pinned to STRING |

---

## Step 3 — Create datasets and stage to GCS

```bash
gcloud config set project "$PROJECT"

for ds in ff_00_raw ff_10_staging ff_20_curated ff_30_marts; do
  bq --location="$REGION" mk -d --description "ARENA FF $ds" "$ds"
done
```

Then upload with slug names (source filenames carry em-dashes and spaces — D8):

```bash
SRC="Written Descriptions_2026_08_7"
for f in "$SRC"/*.csv; do
  b=$(basename "$f" .csv)
  slug=$(echo "$b" \
    | sed -E 's/^3-ARENA-FF-//; s/ — Results-c$//; s/\./_/g; s/-/_/g; s/ +//g' \
    | tr 'A-Z' 'a-z')
  gsutil cp "$f" "$BUCKET/read_${slug}.csv"
done
gsutil ls "$BUCKET" | wc -l   # expect 12
```

This yields `read_g_gr1_2_1x.csv`, `read_g_gr1_2_2.csv`, … — which is what the
load globs in Step 4 match.

> **Correction to the plan.** The comment in Plan §5.1 shows the target name as
> `read_g_gr1_s22.csv`, but its own `sed` produces `read_g_gr1_2_2.csv`. The
> `sed` is right and the globs in §5.2 (`*_2_2*.csv`) are written for it — only
> the comment is stale. Note the loop above globs `*.csv`, so the two `.xlsx`
> files are excluded automatically.

---

## Step 4 — External tables, then materialise raw

Use the external-table route (Plan §5.2 option (a)) — it keeps raw genuinely
immutable and is the only way to get `_FILE_NAME`, which is where `run_id`
comes from.

> **Correction to the plan.** The DDL in §5.2 declares no column list, so
> BigQuery would **autodetect types** — silently breaking the all-STRING rule
> that §5.2 spends its opening paragraph justifying. `--external-ddl` emits the
> explicit column list that prevents this. Do not create these by hand.

```bash
set -euo pipefail
declare -A SECTIONS=( [s21]=20 [s22]=35 [s23]=36 )
declare -A GLOBS=( [s21]='*_2_1*' [s22]='*_2_2*' [s23]='*_2_3*' )

for s in s21 s22 s23; do
  python3 tools/gen_raw_schema.py "${SECTIONS[$s]}" \
    --external-ddl \
    --dataset ff_00_raw \
    --table "ext_read_${s}" \
    --uris "$BUCKET/${GLOBS[$s]}.csv" \
  | bq query --use_legacy_sql=false --location="$REGION"
done
```

Materialise each into an immutable raw table stamped with provenance:

```bash
for s in s21 s22 s23; do
  bq query --use_legacy_sql=false --location="$REGION" "
    CREATE OR REPLACE TABLE \`ff_00_raw.raw_read_${s}\` AS
    SELECT *, _FILE_NAME AS _source_file, CURRENT_TIMESTAMP() AS _loaded_at
    FROM \`ff_00_raw.ext_read_${s}\`;"
done
```

---

## Step 5 — Gate 1

```bash
bq query --use_legacy_sql=false --location="$REGION" "
SELECT 'raw_read_s21' AS t, COUNT(*) n, 596 AS target FROM \`ff_00_raw.raw_read_s21\`
UNION ALL SELECT 'raw_read_s22', COUNT(*), 398 FROM \`ff_00_raw.raw_read_s22\`
UNION ALL SELECT 'raw_read_s23', COUNT(*), 398 FROM \`ff_00_raw.raw_read_s23\`
ORDER BY t;"
```

**596 / 398 / 398, total 1,392.** Anything else — stop and diagnose. Do not
proceed to Phase 2 with a mismatch; every downstream gate inherits the error.

Two failure modes account for almost all Gate 1 misses:

| Symptom | Cause |
|---|---|
| Row count far **higher** than target, garbage rows | `allow_quoted_newlines` missing or false (D1) |
| Row count **lower**, or a file missing entirely | A glob matched the wrong family, or an `.xlsx` slipped in |

Sanity-check provenance too — 12 distinct files, or `run_id` is broken later:

```bash
bq query --use_legacy_sql=false --location="$REGION" "
SELECT COUNT(DISTINCT _source_file) AS files FROM (
  SELECT _source_file FROM \`ff_00_raw.raw_read_s21\`
  UNION ALL SELECT _source_file FROM \`ff_00_raw.raw_read_s22\`
  UNION ALL SELECT _source_file FROM \`ff_00_raw.raw_read_s23\`);"
```

---

## You are now started

Gate 1 green means Phase 1 of the Section 14 checklist is complete. Next is
**Phase 2 — Shape**: write `tools/gen_unpivot.py`, build `stg_response`, then
`dim_archetype` (Gate 2: 398) and `fct_response` (Gate 4: 40,178).

Before writing the unpivot, re-read **Plan §2.2** on the 2.1X replicate. It is
the one part of this dataset that behaves unlike a normal survey export, and
getting `run_id` wrong there double-counts 198 personas in every cross-section
metric.
