#!/bin/bash
set -euo pipefail

VERBOSE=0
ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
        VERBOSE=1
    else
        ARGS+=("$arg")
    fi
done

JSON_FILE="${ARGS[0]:-scripts/package-intervals.json}"
ROOTFS="${ARGS[1]:-/}"
PKG_FILE="${ARGS[2]:-}"
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
export VERBOSE

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

    # Always output stats for the awk summary to parse
    echo "STATS|$pkg|$interval|$count"
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
echo "$PKG_LIST" | xargs -P "$CONCURRENCY" -I {} bash -c 'apply_pkg_xattrs "$@"' _ {} | awk -v verbose="$VERBOSE" -F'|' '
    /^STATS\|/ {
        pkg = $2
        interval = $3
        count = $4
        intervals[interval]++
        files[interval] += count
        if (verbose == 1) {
            print "Applied user.update-interval=" interval " to " pkg " (" count " files)"
        }
        next
    }
    { print }
    END {
        print "\n--- user.update-interval Summary ---"
        for (i in intervals) { print i ": " intervals[i] " packages, " files[i] " files" }
    }'

# Tag compiled system caches to isolate icon/schema/ldconfig updates into a dedicated small layer
echo "Tagging compiled system caches as user.component=system-cache..."
find "${ROOTFS%/}/usr/share/glib-2.0/schemas" "${ROOTFS%/}/usr/share/icons" "${ROOTFS%/}/etc" -type f \( -name "gschemas.compiled" -o -name "icon-theme.cache" -o -name "ld.so.cache" \) 2>/dev/null | while read -r cachefile; do
    setfattr -h -n user.component -v "system-cache" "$cachefile" 2>/dev/null || true
    setfattr -h -n user.update-interval -v "daily" "$cachefile" 2>/dev/null || true
done

# Sweep for any remaining untagged regular files in /usr or /etc to prevent giant catch-all layers
echo "Sweeping for remaining untagged regular files in /usr and /etc..."
find "${ROOTFS%/}/usr" "${ROOTFS%/}/etc" -type f -exec sh -c '
  for f; do
    if ! getfattr -h -n user.component "$f" &>/dev/null; then
      setfattr -h -n user.component -v "image-generated" "$f" 2>/dev/null || true
      setfattr -h -n user.update-interval -v "weekly" "$f" 2>/dev/null || true
    fi
  done
' sh {} +
echo "Fallback component tagging complete."