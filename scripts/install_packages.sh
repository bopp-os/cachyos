#!/bin/bash
set -eo pipefail

# Ensure a target YAML file was provided
YAML_FILE=$1

if [ -z "$YAML_FILE" ] || [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <path-to-analyzed.yml>"
    echo "Example: $0 ./files/base/base-analyzed.yml"
    exit 1
fi

echo "Reading package matrix from: $YAML_FILE"

# Use Python to parse the nested YAML and output: COMPONENT_TAG|INTERVAL|pkg1 pkg2 pkg3
while IFS='|' read -r COMP_TAG INTERVAL PKGS; do
    # Skip empty lines
    [ -z "$COMP_TAG" ] && continue

    # Handle the UPDATE_INTERVAL_TAG
    if [ "$INTERVAL" = "unknown" ]; then
        unset UPDATE_INTERVAL_TAG
        DISPLAY_INTERVAL="[Unset (unknown)]"
        export COMPONENT_TAG="$COMP_TAG"
    else
        export UPDATE_INTERVAL_TAG="$INTERVAL"
        DISPLAY_INTERVAL="$UPDATE_INTERVAL_TAG"
        export COMPONENT_TAG="${COMP_TAG}-${INTERVAL}"
    fi

    echo "======================================================="
    echo "Component:       $COMPONENT_TAG"
    echo "Update Interval: $DISPLAY_INTERVAL"
    echo "Packages:        $PKGS"
    echo "======================================================="

    # Execute pacman installation
    # Use --ask 4 to automatically answer "yes" to conflict removal prompts across different transaction groups
    pacman -Sy --noconfirm --ask 4 --needed $PKGS

    # Cleanup container package cache to keep layers small
    if [ -d "/usr/lib/sysimage/cache/pacman/pkg/" ]; then
        if mountpoint -q /usr/lib/sysimage/cache/pacman/pkg; then
            echo "Cache is externally mounted. Preserving packages on host."
        else
            rm -rf /usr/lib/sysimage/cache/pacman/pkg/*
        fi
    fi

    # Standard /usr/etc relocation (matching your previous Containerfile patterns)
    if [ -e /usr/etc ]; then 
        if [ ! -L /usr/etc ] && [ -n "$(ls -A /usr/etc 2>/dev/null)" ]; then 
            cp -a /usr/etc/* /etc/ 2>/dev/null || true
        fi 
        rm -rf /usr/etc
    fi

done < <(python3 -c "
import yaml, sys
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
    for comp, intervals in data.items():
        for interval, pkgs in intervals.items():
            if pkgs:
                print(f'{comp}|{interval}|{\" \".join(pkgs)}')
except Exception as e:
    print(f'Error parsing YAML: {e}', file=sys.stderr)
    sys.exit(1)
" "$YAML_FILE")

echo "Installation complete for $YAML_FILE."