#!/bin/bash
set -euo pipefail

JSON_FILE="${1:-scripts/package-intervals.json}"
ROOTFS="${2:-/}"
PKG_FILE="${3:-}"
CONCURRENCY=4

if [[ ! -f "$JSON_FILE" ]]; then
    echo "Error: JSON file '$JSON_FILE' not found." >&2
    exit 1
fi

if ! command -v setfattr &>/dev/null || ! command -v getfattr &>/dev/null || ! command -v jq &>/dev/null; then
    echo "Error: 'setfattr'/'getfattr' (attr package) or 'jq' not found. Please install them in the build container." >&2
    exit 1
fi

echo "Applying user.update-interval xattrs to ROOTFS: $ROOTFS using $JSON_FILE"

export JSON_FILE
export ROOTFS

apply_pkg_xattrs() {
    local pkg="$1"
    # Extract interval from JSON, default to weekly if not found
    local interval
    interval=$(jq -r ".\"$pkg\".interval // \"weekly\"" "$JSON_FILE")

    if [[ "$interval" == "weekly" ]] && ! jq -e ".\"$pkg\"" "$JSON_FILE" >/dev/null; then
        echo "Warning: '$pkg' not found in JSON, defaulting to weekly" >&2
    fi

    local count=0
    # List files owned by package, excluding directories (trailing slash)
    while IFS= read -r file; do
        local full_path="${ROOTFS%/}/${file#/}"
        
        # Use -h to avoid dereferencing symlinks, which could traverse out of rootfs or hit RO mounts
        if [[ -e "$full_path" || -L "$full_path" ]]; then
            # Check if a component exists and dynamically append the interval to satisfy Chunkah
            local comp
            comp=$(getfattr -h --absolute-names --only-values -n user.component "$full_path" 2>/dev/null || true)
            if [[ -n "$comp" ]]; then
                # Strip any existing interval suffix natively to prevent stacking (-weekly-daily)
                comp="${comp%-yearly}"
                comp="${comp%-quarterly}"
                comp="${comp%-monthly}"
                comp="${comp%-biweekly}"
                comp="${comp%-weekly}"
                comp="${comp%-daily}"
                setfattr -h -n user.component -v "${comp}-${interval}" "$full_path" 2>/dev/null || true
            fi

            setfattr -h -n user.update-interval -v "$interval" "$full_path" 2>/dev/null || true
            ((count++))
        fi
    done < <(pacman -Qql "$pkg" | grep -v '/$')

    echo "$pkg: $interval ($count files)"
}

export -f apply_pkg_xattrs

# Determine which packages to process
if [[ -n "$PKG_FILE" && -f "$PKG_FILE" ]]; then
    PKG_LIST=$(cat "$PKG_FILE")
else
    PKG_LIST=$(pacman -Qq)
fi

if [[ -z "$PKG_LIST" ]]; then
    echo "No packages to process."
    exit 0
fi

# Run apply in parallel and print a summarized table at the end
echo "$PKG_LIST" | xargs -P "$CONCURRENCY" -I {} bash -c 'apply_pkg_xattrs "$@"' _ {} | awk '
    {
        match($0, /.*: ([a-z]+) \(([0-9]+) files\)/, arr)
        if (arr[1] != "") {
            intervals[arr[1]]++
            files[arr[1]] += arr[2]
        }
    }
    END {
        print "\n--- user.update-interval Summary ---"
        for (i in intervals) { print i ": " intervals[i] " packages, " files[i] " files" }
    }'