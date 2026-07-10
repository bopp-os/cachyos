#!/bin/bash
set -eo pipefail

VERBOSE=0
YAML_FILE=""
for arg in "$@"; do
    if [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
        VERBOSE=1
    else
        YAML_FILE="$arg"
    fi
done

if [ -z "$YAML_FILE" ] || [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 <path-to.yml>"
    echo "Example: $0 ./files/base/base.yaml"
    exit 1
fi

echo "Reading packages from: $YAML_FILE"

# Extract and flatten all packages from the YAML file
PKGS=$(python3 -c "
import yaml, sys
def extract_pkgs(data):
    if isinstance(data, list): return [str(x) for x in data]
    if isinstance(data, dict): return [p for val in data.values() for p in extract_pkgs(val)]
    return []
try:
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
    print(' '.join(extract_pkgs(data)))
except Exception as e:
    print(f'Error parsing YAML: {e}', file=sys.stderr)
    sys.exit(1)
" "$YAML_FILE")

if [ -z "$PKGS" ]; then
    echo "No packages found in $YAML_FILE"
    exit 0
fi

if [ "$VERBOSE" -eq 1 ]; then
    echo "Installing packages: $PKGS"
else
    PKG_COUNT=$(echo "$PKGS" | wc -w)
    echo "Installing $PKG_COUNT packages from $YAML_FILE..."
fi

# Execute pacman installation with a retry loop
MAX_RETRIES=3
RETRY_COUNT=0
SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if [ "$VERBOSE" -eq 1 ]; then
        if pacman -Syu --noconfirm --ask 4 --needed --overwrite '*' $PKGS; then
            SUCCESS=true
            break
        fi
    else
        if pacman -Syu --noconfirm --ask 4 --needed --overwrite '*' $PKGS > /tmp/pacman.log 2>&1; then
            SUCCESS=true
            break
        else
            echo -e "\n================ PACMAN LOG ================"
            cat /tmp/pacman.log || true
            echo -e "============================================\n"
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT+1))
    echo "::warning title=Pacman Install Attempt Failed::Package installation failed! (Attempt $RETRY_COUNT of $MAX_RETRIES)"

    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        WAIT_TIME=$(( 5 * RETRY_COUNT ))
        echo "🔄 Waiting ${WAIT_TIME} seconds before retrying..."
        sleep ${WAIT_TIME}

        # Clean up any partial downloads that might be stuck or corrupted
        echo "🧹 Cleaning up potentially corrupted partial downloads..."
        rm -f /usr/lib/sysimage/cache/pacman/pkg/*.part /var/cache/pacman/pkg/*.part 2>/dev/null || true

        # Try to refresh mirrors if the command is available to recover from 404s
        if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
            echo "🌐 Refreshing mirrors with cachyos-rate-mirrors..."
            timeout 120 cachyos-rate-mirrors < /dev/null || true
        fi
    fi
done

if [ "$SUCCESS" = "false" ]; then
    echo "::error title=Installation Aborted::Failed to install packages after $MAX_RETRIES attempts from $YAML_FILE."
    exit 1
fi

# Cleanup container package cache to keep layers small
if [ -d "/usr/lib/sysimage/cache/pacman/pkg/" ]; then
    if mountpoint -q /usr/lib/sysimage/cache/pacman/pkg; then
        echo "Cache is externally mounted. Preserving packages on host."
    else
        rm -rf /usr/lib/sysimage/cache/pacman/pkg/*
    fi
fi

# Standard /usr/etc relocation
if [ -e /usr/etc ]; then 
    if [ ! -L /usr/etc ] && [ -n "$(ls -A /usr/etc 2>/dev/null)" ]; then 
        cp -a /usr/etc/* /etc/ 2>/dev/null || true
    fi 
    rm -rf /usr/etc
fi

echo "Installation complete for $YAML_FILE."

# Ensure no background GnuPG daemons are left hanging to prevent podman build freezes
pkill -9 gpg-agent || true
pkill -9 dirmngr || true
pkill -9 keyboxd || true
pkill -9 scdaemon || true
pkill -9 dbus-daemon || true
pkill -9 dbus-broker || true
pkill -9 gvfsd || true
pkill -9 dconf-service || true