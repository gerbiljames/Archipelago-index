#!/bin/bash
# Bulk-seed fuzz baselines locally, one container per (world, latest-version)
# pair from main's index.lock. Records to apdiff-viewer with pr_number=null
# so the data lands as the "main" baseline that PR fuzz comparisons read.
#
# Run from anywhere; INDEX_REPO defaults to this script's parent dir.
#
# Required (in env):
#   FUZZ_API_KEY        X-Api-Key for apdiff-viewer's POST /api/fuzz-results
#
# Optional (in env, with defaults):
#   INDEX_REPO          path to the index repo checkout
#                       (default: parent of this script)
#   AP_CHECKER_IMAGE    image with apwm + run_fuzz.py + aggregate_fuzz.py
#                       (default: registry.git.mooinglemur.com/...)
#   APDIFF_BASE_URL     apdiff-viewer base URL (default: ionium.us instance)
#   FUZZ_RUNS_FULL      runs for `default` and `no-restrictive-starts` variants
#                       (default: 5000)
#   FUZZ_RUNS_CHECK     runs for the nine `check-*` variants
#                       (default: 500)
#   PARALLEL_PAIRS      how many pairs to process at once (default: 1).
#                       Each pair already runs its inner fuzz with -j 4, so
#                       beyond 2-3 you'll oversaturate the host.
#   ONLY_WORLDS         optional space-separated allowlist; if set, only the
#                       named worlds are baselined (e.g. "alttp animal_well").
#
# Ctrl+C: stops the loop, kills any running containers we started (named with
# a script-PID prefix), and exits 130. Subshells in parallel mode are torn
# down via the same prefix-based docker kill.

set -uo pipefail

: "${FUZZ_API_KEY:?FUZZ_API_KEY env var required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${INDEX_REPO:=$(cd "$SCRIPT_DIR/.." && pwd)}"
: "${AP_CHECKER_IMAGE:=registry.git.mooinglemur.com/ionium-ap/archipelago-index-ci/ap-checker:latest}"
: "${APDIFF_BASE_URL:=https://apdiff-viewer.ionium.us}"
: "${FUZZ_RUNS_FULL:=5000}"
: "${FUZZ_RUNS_CHECK:=500}"
: "${PARALLEL_PAIRS:=1}"
: "${ONLY_WORLDS:=}"

if [ ! -f "$INDEX_REPO/index.lock" ]; then
    echo "INDEX_REPO=$INDEX_REPO has no index.lock" >&2
    exit 2
fi

cd "$INDEX_REPO"

# All docker containers we start get this prefix in their --name so the
# Ctrl+C trap can find them via `docker ps --filter "name=^${CONTAINER_PFX}"`.
CONTAINER_PFX="ap-baseline-$$"
INTERRUPTED=0
CHILD_PIDS=()
PAIRS_FILE=""

kill_containers() {
    local running
    running=$(docker ps --filter "name=^${CONTAINER_PFX}" --format '{{.Names}}' 2>/dev/null || true)
    if [ -n "$running" ]; then
        echo "$running" | xargs -r docker kill >/dev/null 2>&1 || true
    fi
}

on_interrupt() {
    if [ "$INTERRUPTED" = 1 ]; then
        # Second Ctrl+C -- escalate. Kill everything we can find, exit harder.
        echo "second interrupt; killing everything and exiting now" >&2
        kill_containers
        if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
            kill -KILL "${CHILD_PIDS[@]}" 2>/dev/null || true
        fi
        exit 130
    fi
    INTERRUPTED=1
    echo >&2
    echo "interrupting; killing running containers (Ctrl+C again to force-kill)" >&2
    kill_containers
    if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
        kill -INT "${CHILD_PIDS[@]}" 2>/dev/null || true
    fi
}
trap on_interrupt INT TERM

cleanup_exit() {
    local rc=$?
    # Belt + suspenders for normal exits.
    kill_containers
    [ -n "$PAIRS_FILE" ] && rm -f "$PAIRS_FILE"
    exit "$rc"
}
trap cleanup_exit EXIT

echo "Pulling $AP_CHECKER_IMAGE ..."
docker pull "$AP_CHECKER_IMAGE"
[ "$INTERRUPTED" = 1 ] && exit 130

VARIANTS=$(docker run --rm --entrypoint /usr/local/bin/run_fuzz.py "$AP_CHECKER_IMAGE" list)
PAIRS_FILE=$(mktemp)

# Emit (world, latest-version) per line. Latest is by semver where parseable;
# falls back to lexicographic for weird inputs.
ONLY_WORLDS="$ONLY_WORLDS" python3 - <<'PY' > "$PAIRS_FILE"
import os, sys, tomllib
try:
    from packaging.version import Version, InvalidVersion
except ImportError:
    sys.stderr.write("packaging not installed; install with `pip install packaging`\n")
    sys.exit(1)

allow = set((os.environ.get("ONLY_WORLDS") or "").split())

with open("index.lock", "rb") as f:
    data = tomllib.load(f)

def vkey(v):
    try:
        return (0, Version(v))
    except InvalidVersion:
        return (1, v)

for world, versions in data.items():
    if not versions:
        continue
    if allow and world not in allow:
        continue
    latest = max(versions.keys(), key=vkey)
    print(f"{world}\t{latest}")
PY

PAIR_COUNT=$(wc -l < "$PAIRS_FILE")
echo "Baselining $PAIR_COUNT (world, latest-version) pairs at parallelism=$PARALLEL_PAIRS"
echo "  FUZZ_RUNS_FULL=$FUZZ_RUNS_FULL  FUZZ_RUNS_CHECK=$FUZZ_RUNS_CHECK"
echo

# Slug a (world, version) into a container-name-safe string.
container_slug() {
    printf '%s' "$1" | tr -c '[:alnum:]_-' '_'
}

# Files in the bind-mounted workdir get written as root (the container user),
# so the host user can't rm them. Delegate cleanup to a one-shot container
# with the same image, which has the perms to nuke its own previous output.
nuke_wd() {
    local wd="$1"
    [ -z "$wd" ] && return 0
    [ ! -d "$wd" ] && return 0
    docker run --rm -v "$wd:/work" \
        --entrypoint /bin/sh \
        "$AP_CHECKER_IMAGE" \
        -c 'find /work -mindepth 1 -delete' \
        >/dev/null 2>&1 || true
    # /work itself was the bind mount target; rm the host-side empty dir.
    rmdir "$wd" 2>/dev/null || rm -rf "$wd" 2>/dev/null || true
}

# Run all docker steps for one pair. Returns 0 on success-or-skip, non-zero
# if interrupted mid-flight (signals the outer loop to break).
process_pair() {
    local w="$1" v="$2"
    [ "$INTERRUPTED" = 1 ] && return 1

    local wd
    wd=$(mktemp -d)
    local cn_base="${CONTAINER_PFX}-$(container_slug "${w}-${v}")"

    echo "=== baseline $w:$v ==="

    cp "$INDEX_REPO/index.toml" "$INDEX_REPO/index.lock" "$wd/"
    cp -r "$INDEX_REPO/index" "$wd/"
    [ -d "$INDEX_REPO/apworlds" ] && cp -r "$INDEX_REPO/apworlds" "$wd/" || true
    mkdir -p "$wd/output/apworlds" "$wd/fuzz-report"

    docker run --rm --name "${cn_base}-dl" \
        -v "$wd:/work" -w /work "$AP_CHECKER_IMAGE" \
        apwm download -i . -p "$w:$v" -d output/apworlds
    local rc=$?
    if [ "$INTERRUPTED" = 1 ]; then nuke_wd "$wd"; return 1; fi
    if [ "$rc" -ne 0 ]; then
        echo "  skip: apwm download failed ($rc) for $w:$v" >&2
        nuke_wd "$wd"
        return 0
    fi

    docker run --rm --name "${cn_base}-build" \
        -v "$wd:/work" -w /work \
        -e BASELINE_PAIRS="$w:$v" \
        "$AP_CHECKER_IMAGE" \
        /usr/local/bin/build_baseline_changes.py >/dev/null
    rc=$?
    if [ "$INTERRUPTED" = 1 ]; then nuke_wd "$wd"; return 1; fi
    if [ "$rc" -ne 0 ]; then
        echo "  skip: build_baseline_changes.py failed ($rc) for $w:$v" >&2
        nuke_wd "$wd"
        return 0
    fi

    for variant in $VARIANTS; do
        [ "$INTERRUPTED" = 1 ] && { nuke_wd "$wd"; return 1; }
        echo "  -- $w:$v $variant"
        # variant name is already safe (alphanum + dashes).
        docker run --rm --network=none --name "${cn_base}-${variant}" \
            -v "$wd:/work" -w /work \
            -e PYTHONPATH=/usr/local/lib:/ap/ap-worker:/ap/archipelago \
            -e FUZZ_RUNS_FULL -e FUZZ_RUNS_CHECK \
            "$AP_CHECKER_IMAGE" \
            /usr/local/bin/run_with_netaudit.sh /usr/local/bin/run_fuzz.py run \
                /ap/supported_worlds/ /work/output/apworlds/ \
                "$w" "$v" "$variant" "/work/fuzz-report/$w/$v/$variant" \
            >/dev/null 2>&1 \
            || echo "    variant $variant failed (continuing)" >&2
    done
    [ "$INTERRUPTED" = 1 ] && { nuke_wd "$wd"; return 1; }

    docker run --rm --name "${cn_base}-agg" \
        -v "$wd:/work" -w /work \
        -e APDIFF_BASE_URL -e FUZZ_API_KEY \
        "$AP_CHECKER_IMAGE" \
        /usr/local/bin/aggregate_fuzz.py /work/fuzz-report /work/output/changes.json \
        >/dev/null || echo "    aggregate failed for $w:$v" >&2

    nuke_wd "$wd"
    return 0
}

reap_completed() {
    local -a new=()
    local p
    if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
        for p in "${CHILD_PIDS[@]}"; do
            if kill -0 "$p" 2>/dev/null; then
                new+=("$p")
            fi
        done
    fi
    CHILD_PIDS=()
    if [ "${#new[@]}" -gt 0 ]; then
        CHILD_PIDS=("${new[@]}")
    fi
}

# Main loop. Sequential or parallel depending on PARALLEL_PAIRS.
while IFS=$'\t' read -r w v; do
    [ "$INTERRUPTED" = 1 ] && break
    [ -z "$w" ] && continue

    if [ "$PARALLEL_PAIRS" -le 1 ]; then
        process_pair "$w" "$v" || break
    else
        # Wait for a slot.
        while [ "${#CHILD_PIDS[@]}" -ge "$PARALLEL_PAIRS" ]; do
            wait -n 2>/dev/null || true
            reap_completed
            [ "$INTERRUPTED" = 1 ] && break
        done
        [ "$INTERRUPTED" = 1 ] && break
        process_pair "$w" "$v" &
        CHILD_PIDS+=("$!")
    fi
done < "$PAIRS_FILE"

# Drain any in-flight background jobs.
if [ "$PARALLEL_PAIRS" -gt 1 ]; then
    wait 2>/dev/null || true
fi

if [ "$INTERRUPTED" = 1 ]; then
    echo "interrupted" >&2
    exit 130
fi

echo
echo "done"
