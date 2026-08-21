#!/usr/bin/env bash
#
# Stage the 12 READ-modality respondent CSVs to GCS under the Phase 1 filename
# convention:
#
#     read_{g|s}_{gr1|gr2}_s2_{1|2|3}[x].csv
#
# Why rename at all: the source names carry em-dashes and spaces
# ("3-ARENA-FF-G-gr1-2.2 — Results-c.csv"), which are hostile to GCS URIs and to
# every glob downstream. The `s2_` segment is what dim_run's extractor parses to
# recover section_code, so it is load-bearing, not cosmetic.
#
# Only the 12 .csv files migrate. The 2 stray .xlsx in the source folder are
# Excel renderings of CSVs already in the set (plan doc §5.1).
#
# Usage:
#     ./tools/slugify_upload.sh --dry-run    # print the mapping, upload nothing
#     ./tools/slugify_upload.sh              # upload, then verify
#
# Reads GCS_PREFIX from config.env if not already exported.

set -euo pipefail

SRC="${SRC:-Written Descriptions_2026_08_7}"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

EXPECTED_COUNT=12

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

[[ -d "$SRC" ]] || { echo "ERROR: source directory not found: $SRC" >&2; exit 1; }

# --- build the mapping ----------------------------------------------------
#
# Parsed rather than sed-substituted so that an unexpected filename is a hard
# error instead of a silently mangled object name.

srcs=()
tgts=()

while IFS= read -r f; do
  stem="$(basename "$f" .csv)"

  if [[ ! "$stem" =~ ^3-ARENA-FF-([GS])-(gr[12])-2\.([123])(X?) ]]; then
    echo "ERROR: unrecognised filename, refusing to guess a target name:" >&2
    echo "       $stem" >&2
    exit 1
  fi

  creative="$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')"
  group="${BASH_REMATCH[2]}"
  section="${BASH_REMATCH[3]}"
  replicate="$(printf '%s' "${BASH_REMATCH[4]}" | tr 'A-Z' 'a-z')"

  srcs+=("$f")
  tgts+=("read_${creative}_${group}_s2_${section}${replicate}.csv")
done < <(find "$SRC" -maxdepth 1 -name '*.csv' | sort)

# --- validate the mapping before touching the network ---------------------

if [[ "${#srcs[@]}" -ne "$EXPECTED_COUNT" ]]; then
  echo "ERROR: found ${#srcs[@]} CSVs in '$SRC', expected $EXPECTED_COUNT." >&2
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
EOF
)"

if ! diff -q <(printf '%s\n' "${tgts[@]}" | sort) <(printf '%s\n' "$expected_set") >/dev/null; then
  echo "ERROR: mapping does not match the 12 expected object names." >&2
  diff <(printf '%s\n' "${tgts[@]}" | sort) <(printf '%s\n' "$expected_set") >&2 || true
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
  echo "Dry run — nothing uploaded. Re-run without --dry-run to stage these 12 files."
  exit 0
fi

# --- upload ---------------------------------------------------------------
#
# gcloud storage cp verifies a CRC32C checksum per object, so a truncated or
# corrupted upload fails here rather than surfacing as a bad row count at Gate 1.

for i in "${!srcs[@]}"; do
  echo "Uploading ${tgts[$i]} ..."
  gcloud storage cp "${srcs[$i]}" "$GCS_PREFIX/${tgts[$i]}"
done

# --- verify ---------------------------------------------------------------

echo
echo "Verifying ..."
remote="$(gcloud storage ls "$GCS_PREFIX/" | sed 's|.*/||' | grep -v '^$' | sort)"
remote_count="$(printf '%s\n' "$remote" | wc -l | tr -d ' ')"

if [[ "$remote_count" -ne "$EXPECTED_COUNT" ]]; then
  echo "GATE FAILED: $GCS_PREFIX holds $remote_count objects, expected $EXPECTED_COUNT." >&2
  printf '%s\n' "$remote" >&2
  exit 1
fi

if ! diff -q <(printf '%s\n' "$remote") <(printf '%s\n' "$expected_set") >/dev/null; then
  echo "GATE FAILED: object names in GCS do not match the expected set." >&2
  diff <(printf '%s\n' "$remote") <(printf '%s\n' "$expected_set") >&2 || true
  exit 1
fi

echo "GATE PASSED: 12 objects staged with the expected names."
