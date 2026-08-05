#!/bin/bash
set -euo pipefail

VERBOSE=0
for arg in "$@"; do
    if [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
        VERBOSE=1
    fi
done

# Locate package-intervals.json database if available
JSON_FILE=""
for candidate in /tmp/package-intervals.json /tmp/scripts/package-intervals.json /usr/share/boppos/package-intervals.json scripts/package-intervals.json; do
    if [[ -f "$candidate" ]]; then
        JSON_FILE="$candidate"
        break
    fi
done

# Pre-load package intervals mapping into an associative array
declare -A PKG_INTERVALS
if [[ -n "$JSON_FILE" ]] && command -v jq &>/dev/null; then
    while IFS="=" read -r k v; do
        if [[ -n "$k" && -n "$v" ]]; then
            PKG_INTERVALS["$k"]="$v"
        fi
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value.interval)"' "$JSON_FILE" 2>/dev/null || true)
fi

while read -r pkgname; do
    [[ -z "$pkgname" ]] && continue

    # Query package files, catching exit code if pacman fails
    if ! file_list=$(pacman -Qlq "$pkgname" 2>/dev/null); then
        continue
    fi

    # Lookup update interval from JSON, default to "weekly"
    interval="${UPDATE_INTERVAL_TAG:-${PKG_INTERVALS[$pkgname]:-weekly}}"
    base_comp="${COMPONENT_TAG:-$pkgname}"
    comp_val="${base_comp}-${interval}"

    while read -r filepath; do
        # Target regular files (ignore symlinks and directories)
        if [[ -f "$filepath" && ! -L "$filepath" ]]; then
            setfattr -h -n user.component -v "$comp_val" "$filepath" 2>/dev/null || true
            setfattr -h -n user.update-interval -v "$interval" "$filepath" 2>/dev/null || true
            if [[ "$VERBOSE" -eq 1 ]]; then
                echo "Assigned user.component=$comp_val user.update-interval=$interval to $filepath"
            fi
        fi
    done <<< "$file_list"
done
