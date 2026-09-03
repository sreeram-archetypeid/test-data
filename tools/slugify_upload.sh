#!/usr/bin/env bash
#
# Stage the 14 READ-modality respondent CSVs to GCS under the Phase 1 filename
# convention:
#
#     read_{g|s}_{gr1|gr2}_s{1|2}_{1|2|3|4}[x].csv
#
# Why rename at all: the source names carry em-dashes and spaces
# ("3-ARENA-FF-G-gr1-2.2 — Results-c.csv"), which are hostile to GCS URIs and to
# every glob downstream. The `s{major}_{section}` segment is what dim_run's
# extractor parses to recover section_code, so it is load-bearing, not cosmetic.
#
# The section-1.4 files (AGE / ZIPCODE / GENDER / INCOME, added after Phase 1)
# arrived in a separate delivery folder, so the source is a LIST of directories
# rather than one. Both the major and minor section numbers are captured: an
# earlier version hardcoded `s2_`, which would have renamed 1.4 to `s2_4x` --
# a name that looks right and silently collides with the 2.x namespace.
#
# Only the 14 .csv files migrate. The 2 stray .xlsx in the source folder are
# Excel renderings of CSVs already in the set (plan doc §5.1).
#
# Usage:
#     ./tools/slugify_upload.sh --dry-run    # print the mapping, upload nothing
#     ./tools/slugify_upload.sh              # upload, then verify
#
# Reads GCS_PREFIX from config.env if not already exported.

set -euo pipefail

# Source folders, in delivery order. Override with SRC_DIRS="a:b" if needed.
IFS=':' read -r -a SRC_DIRS <<< "${SRC_DIRS:-Written Descriptions_2026_08_7:Written Descriptions_2026_08_18}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

EXPECTED_COUNT=14

# --- resolve config -------------------------------------------------------

if [[ -z "${GCS_PREFIX:-}" ]]; then
  if [[ -f config.env ]]; then
    # shellcheck disable=SC1091
    source config.env
  else
    echo "ERROR: GCS_PREFIX is unset and ./config.env was not found." >&2
    echo "       Run this from the repo root, or export GCS_PREFIX first." >&2
    exit 1
  fi
fi
: "${GCS_PREFIX:?GCS_PREFIX resolved empty — check config.env}"

for d in "${SRC_DIRS[@]}"; do
  [[ -d "$d" ]] || { echo "ERROR: source directory not found: $d" >&2; exit 1; }
done

# --- build the mapping ----------------------------------------------------
#
# Parsed rather than sed-substituted so that an unexpected filename is a hard
# error instead of a silently mangled object name.

srcs=()
tgts=()

while IFS= read -r f; do
  stem="$(basename "$f" .csv)"

  # The replicate marker is upper-case on the 2.x files ("2.1X") and lower-case
  # on the 1.4 delivery ("1.4x"), so match either. Missing it here does not
  # error -- it silently drops the marker and produces a target name that looks
  # correct, which is how it slipped through the first time.
  if [[ ! "$stem" =~ ^3-ARENA-FF-([GS])-(gr[12])-([12])\.([1-4])([Xx]?) ]]; then
    echo "ERROR: unrecognised filename, refusing to guess a target name:" >&2
    echo "       $stem" >&2
    exit 1
  fi

  creative="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
  group="${BASH_REMATCH[2]}"
  major="${BASH_REMATCH[3]}"
  section="${BASH_REMATCH[4]}"
  replicate="$(printf '%s' "${BASH_REMATCH[5]}" | tr 'A-Z' 'a-z')"

  srcs+=("$f")
  tgts+=("read_${creative}_${group}_s${major}_${section}${replicate}.csv")
done < <(find "${SRC_DIRS[@]}" -maxdepth 1 -name '*.csv' | sort)

# --- validate the mapping before touching the network ---------------------

if [[ "${#srcs[@]}" -ne "$EXPECTED_COUNT" ]]; then
  echo "ERROR: found ${#srcs[@]} CSVs in '${SRC_DIRS[*]}', expected $EXPECTED_COUNT." >&2
  exit 1
fi

dupes="$(printf '%s\n' "${tgts[@]}" | sort | uniq -d)"
if [[ -n "$dupes" ]]; then
  echo "ERROR: target names collide — two sources map to the same object:" >&2
  printf '       %s\n' "$dupes" >&2
  exit 1
fi

expected_set="$(cat <<'EOF'
read_g_gr1_s2_1x.csv
read_g_gr1_s2_2.csv
read_g_gr1_s2_3.csv
read_g_gr2_s2_1.csv
read_g_gr2_s2_2.csv
read_g_gr2_s2_3.csv
read_s_gr1_s2_1.csv
read_s_gr1_s2_2.csv
read_s_gr1_s2_3.csv
read_s_gr2_s2_1x.csv
read_s_gr2_s2_2.csv
read_s_gr2_s2_3.csv
read_g_gr1_s1_4x.csv
read_s_gr1_s1_4x.csv
EOF
)"

# Both sides sorted: the literal list below is a SET, so its order in the
# heredoc must not be able to fail the check.
if ! diff -q <(printf '%s\n' "${tgts[@]}" | sort) <(printf '%s\n' "$expected_set" | sort) >/dev/null; then
  echo "ERROR: mapping does not match the $EXPECTED_COUNT expected object names." >&2
  diff <(printf '%s\n' "${tgts[@]}" | sort) <(printf '%s\n' "$expected_set" | sort) >&2 || true
  exit 1
fi

# --- report ---------------------------------------------------------------

echo "Destination: $GCS_PREFIX"
echo
for i in "${!srcs[@]}"; do
  printf '  %-44s ->  %s\n' "$(basename "${srcs[$i]}")" "${tgts[$i]}"
done
echo

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run — nothing uploaded. Re-run without --dry-run to stage these ${#srcs[@]} files."
  exit 0
fi

# --- transport ------------------------------------------------------------
#
# gcloud when it is available (a developer machine), tools/gcs_helper.py when it
# is not. The web sandbox cannot install the SDK -- dl.google.com is blocked by
# network policy -- and without a fallback the staging step simply cannot run
# there, which is how the section-1.4 files went unlanded for so long.
#
# Both transports verify the uploaded byte count server-side: gcloud by CRC32C,
# the helper by comparing the returned size. A truncated upload must fail here
# rather than surfacing as a wrong row count at Gate 1.

if command -v gcloud >/dev/null 2>&1; then
  put() { gcloud storage cp "$1" "$GCS_PREFIX/$2"; }
  list_remote() { gcloud storage ls "$GCS_PREFIX/" | sed 's|.*/||' | grep -v '^$'; }
else
  echo "gcloud not found — using tools/gcs_helper.py (needs GOOGLE_ACCESS_TOKEN)."
  put() { python3 tools/gcs_helper.py cp "$1" "$2"; }
  list_remote() { python3 tools/gcs_helper.py ls; }
fi

# --- upload ---------------------------------------------------------------

for i in "${!srcs[@]}"; do
  echo "Uploading ${tgts[$i]} ..."
  put "${srcs[$i]}" "${tgts[$i]}"
done

# --- verify ---------------------------------------------------------------

echo
echo "Verifying ..."
remote="$(list_remote | sort)"
remote_count="$(printf '%s\n' "$remote" | wc -l | tr -d ' ')"

if [[ "$remote_count" -ne "$EXPECTED_COUNT" ]]; then
  echo "GATE FAILED: $GCS_PREFIX holds $remote_count objects, expected $EXPECTED_COUNT." >&2
  printf '%s\n' "$remote" >&2
  exit 1
fi

if ! diff -q <(printf '%s\n' "$remote" | sort) <(printf '%s\n' "$expected_set" | sort) >/dev/null; then
  echo "GATE FAILED: object names in GCS do not match the expected set." >&2
  diff <(printf '%s\n' "$remote" | sort) <(printf '%s\n' "$expected_set" | sort) >&2 || true
  exit 1
fi

echo "GATE PASSED: $EXPECTED_COUNT objects staged with the expected names."
