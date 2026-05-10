#!/bin/bash
# Bootstrap apdiff-viewer's apworld_artifacts dedup table from the current
# index. Walks index.lock for the canonical (world, version) pairs, downloads
# all apworlds via `apwm download`, and POSTs each to /api/import on the
# apdiff-viewer.
#
# Requires (in env):
#   APDIFF_BASE_URL   e.g. https://apdiff-viewer.ionium.us
#   APDIFF_API_KEY    matching the apdiff-viewer's APDIFF_API_KEY
#
# Run from the index repo root. Idempotent: re-uploads land as already-stored.
# Exit code: 0 on full success, 1 if any uploads failed.

set -euo pipefail

: "${APDIFF_BASE_URL:?APDIFF_BASE_URL is required}"
: "${APDIFF_API_KEY:?APDIFF_API_KEY is required}"

if [ ! -f index.lock ]; then
    echo "must be run from the index repo root (no index.lock here)" >&2
    exit 2
fi

DOWNLOAD_DIR="${BOOTSTRAP_DOWNLOAD_DIR:-/tmp/all-apworlds}"
mkdir -p "$DOWNLOAD_DIR"

echo "downloading every indexed apworld into $DOWNLOAD_DIR ..."
apwm download -i . -d "$DOWNLOAD_DIR"

PAIRS_TSV=$(mktemp)
trap 'rm -f "$PAIRS_TSV"' EXIT

python3 - <<'PY' > "$PAIRS_TSV"
import tomllib, sys
with open("index.lock", "rb") as f:
    data = tomllib.load(f)
for world, versions in data.items():
    for version in versions:
        sys.stdout.write(f"{world}\t{version}\n")
PY

PAIR_COUNT=$(wc -l < "$PAIRS_TSV")
echo "uploading $PAIR_COUNT (world, version) pairs to $APDIFF_BASE_URL ..."

OK=0
SKIP=0
FAIL=0

while IFS=$'\t' read -r world version; do
    file="$DOWNLOAD_DIR/${world}-${version}.apworld"
    if [ ! -f "$file" ]; then
        echo "SKIP missing on disk: $world $version" >&2
        SKIP=$((SKIP+1))
        continue
    fi
    w_enc=$(printf '%s' "$world"   | jq -sRr @uri)
    v_enc=$(printf '%s' "$version" | jq -sRr @uri)
    if curl -fsS -X POST \
         -H "X-Api-Key: $APDIFF_API_KEY" \
         -H "Content-Type: application/octet-stream" \
         --data-binary @"$file" \
         "$APDIFF_BASE_URL/api/import?world=${w_enc}&version=${v_enc}" \
         >/dev/null; then
        OK=$((OK+1))
    else
        echo "FAIL: $world $version" >&2
        FAIL=$((FAIL+1))
    fi
done < "$PAIRS_TSV"

echo "done: ok=$OK skip=$SKIP fail=$FAIL"
[ "$FAIL" -eq 0 ]
