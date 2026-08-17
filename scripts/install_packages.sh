#!/bin/bash
set -eo pipefail

VERBOSE=0
DOWNLOAD_ONLY=0
YAML_FILE=""
for arg in "$@"; do
    if [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
        VERBOSE=1
    elif [[ "$arg" == "--download-only" || "$arg" == "--download" ]]; then
        DOWNLOAD_ONLY=1
    else
        YAML_FILE="$arg"
    fi
done

if [ -z "$YAML_FILE" ] || [ ! -f "$YAML_FILE" ]; then
    echo "Usage: $0 [--verbose|-v] [--download-only] <path-to.yml>"
    echo "Example: $0 --download-only ./files/base/base.yaml"
    exit 1
fi

echo "Reading package sections from: $YAML_FILE"

# Extract block sections from YAML file
SECTIONS_OUTPUT=$(python3 -c "
import sys, re
try:
    import yaml
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f) or {}
except Exception:
    data = {}

if isinstance(data, dict) and data:
    for block_name, val in data.items():
        pkgs = []
        if isinstance(val, list):
            pkgs = [str(x) for x in val]
        elif isinstance(val, dict):
            def extract(d):
                res = []
                if isinstance(d, list): return [str(x) for x in d]
                if isinstance(d, dict):
                    for v in d.values(): res.extend(extract(v))
                return res
            pkgs = extract(val)
        if pkgs:
            print(f'SECTION::{block_name}::' + ' '.join(pkgs))
else:
    current_block = 'default'
    block_pkgs = {}
    with open(sys.argv[1]) as f:
        for line in f:
            m_block = re.match(r'^([a-zA-Z0-9_\-]+):', line)
            if m_block:
                current_block = m_block.group(1)
            m_item = re.match(r'^\s*-\s+([a-zA-Z0-9_\-\.\+]+)', line)
            if m_item:
                block_pkgs.setdefault(current_block, []).append(m_item.group(1))
    for b_name, pkgs in block_pkgs.items():
        if pkgs:
            print(f'SECTION::{b_name}::' + ' '.join(pkgs))
" "$YAML_FILE")

if [ -z "$SECTIONS_OUTPUT" ]; then
    echo "No package sections found in $YAML_FILE"
    exit 0
fi

# Flatten all packages for Phase 1 Download
ALL_PKGS=$(echo "$SECTIONS_OUTPUT" | sed 's/SECTION::[^:]*:://' | tr '\n' ' ')

# Determine network-isolated execution wrapper if unshare is available
ISOLATE_CMD=""
if command -v unshare >/dev/null 2>&1; then
    if unshare -n true 2>/dev/null; then
        ISOLATE_CMD="unshare -n"
    elif unshare -r -n true 2>/dev/null; then
        ISOLATE_CMD="unshare -r -n"
    elif unshare -U -n true 2>/dev/null; then
        ISOLATE_CMD="unshare -U -n"
    fi
fi

if [ -n "$ISOLATE_CMD" ]; then
    echo "🔒 Network isolation wrapper active: $ISOLATE_CMD"
else
    echo "⚠️ Network isolation wrapper unshare unavailable in current container environment."
fi

# Phase 1: Download all packages and transaction dependencies at once
MAX_RETRIES=3
RETRY_COUNT=0
DOWNLOAD_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "📦 Phase 1: Pre-fetching package archives for $YAML_FILE..."

    DOWNLOAD_EXEC="pacman -Sw --noconfirm --ask 4 --needed --overwrite '*' $ALL_PKGS"

    if [ "$VERBOSE" -eq 1 ]; then
        if $DOWNLOAD_EXEC 2>&1 | tee /tmp/pacman-download.log; then
            DOWNLOAD_SUCCESS=true
            echo "✅ Download phase complete for $YAML_FILE."
            break
        else
            echo -e "\n================ PACMAN DOWNLOAD LOG ================"
            cat /tmp/pacman-download.log || true
            echo -e "=====================================================\n"
        fi
    else
        if $DOWNLOAD_EXEC > /tmp/pacman-download.log 2>&1; then
            DOWNLOAD_SUCCESS=true
            echo "✅ Download phase complete for $YAML_FILE."
            break
        else
            echo -e "\n================ PACMAN DOWNLOAD LOG ================"
            cat /tmp/pacman-download.log || true
            echo -e "=====================================================\n"
        fi
    fi

    RETRY_COUNT=$((RETRY_COUNT+1))
    echo "::warning title=Download Attempt Failed::Package download attempt $RETRY_COUNT of $MAX_RETRIES failed!"
    [ $RETRY_COUNT -lt $MAX_RETRIES ] && sleep $(( 5 * RETRY_COUNT ))
done

if [ "$DOWNLOAD_SUCCESS" = "false" ]; then
    echo "::error title=Download Aborted::Failed to download packages from $YAML_FILE."
    exit 1
fi

if [ "$DOWNLOAD_ONLY" -eq 1 ]; then
    echo "ℹ️ --download-only mode active. Skipping installation phase."
    exit 0
fi

# Phase 2: Install each section block separately with network isolation
TOTAL_SECTIONS=$(echo "$SECTIONS_OUTPUT" | grep -c "^SECTION::" || true)
CURRENT_SEC=0

echo "🔒 Phase 2: Installing $TOTAL_SECTIONS package blocks with network isolation..."

while IFS= read -r sec_line; do
    [[ -z "$sec_line" ]] && continue
    CURRENT_SEC=$((CURRENT_SEC + 1))
    
    SEC_NAME=$(echo "$sec_line" | cut -d':' -f3)
    SEC_PKGS=$(echo "$sec_line" | cut -d':' -f5)
    SEC_COUNT=$(echo "$SEC_PKGS" | wc -w)

    echo ""
    echo "======================================================================"
    echo "📦 Block [$CURRENT_SEC/$TOTAL_SECTIONS]: $SEC_NAME ($SEC_COUNT packages)"
    echo "======================================================================"
    
    if [ "$VERBOSE" -eq 1 ]; then
        echo "Packages in $SEC_NAME: $SEC_PKGS"
    fi

    SEC_RETRY=0
    SEC_SUCCESS=false
    INSTALL_EXEC="$ISOLATE_CMD pacman -S --noconfirm --ask 4 --needed --overwrite '*' $SEC_PKGS"

    while [ $SEC_RETRY -lt $MAX_RETRIES ]; do
        if [ "$VERBOSE" -eq 1 ]; then
            if $INSTALL_EXEC; then
                SEC_SUCCESS=true
                break
            fi
        else
            if $INSTALL_EXEC > /tmp/pacman-block.log 2>&1; then
                SEC_SUCCESS=true
                break
            else
                echo -e "\n================ PACMAN LOG [$SEC_NAME] ================"
                cat /tmp/pacman-block.log || true
                echo -e "========================================================\n"
            fi
        fi

        SEC_RETRY=$((SEC_RETRY + 1))
        echo "::warning::Block $SEC_NAME installation attempt $SEC_RETRY failed! Retrying..."
        [ $SEC_RETRY -lt $MAX_RETRIES ] && sleep 3
    done

    if [ "$SEC_SUCCESS" = "false" ]; then
        echo "::error::Failed to install package block $SEC_NAME from $YAML_FILE."
        exit 1
    fi
    echo "✅ Block [$CURRENT_SEC/$TOTAL_SECTIONS] ($SEC_NAME) installed successfully."

done <<< "$SECTIONS_OUTPUT"

# Cleanup container package cache to keep layers small
CACHE_PATH="/var/cache/pacman/pkg"
if [ -d "$CACHE_PATH" ]; then
    if mountpoint -q "$CACHE_PATH" || [ -n "$(findmnt -n "$CACHE_PATH" 2>/dev/null)" ] || [ "$DOWNLOAD_ONLY" -eq 1 ]; then
        echo "Pacman package cache is mounted. Preserving packages on host storage."
    else
        echo "Cleaning unmounted in-container package cache..."
        rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
    fi
fi

# Standard /usr/etc relocation
if [ -e /usr/etc ]; then 
    if [ ! -L /usr/etc ] && [ -n "$(ls -A /usr/etc 2>/dev/null)" ]; then 
        cp -a /usr/etc/* /etc/ 2>/dev/null || true
    fi 
    rm -rf /usr/etc
fi

echo "All $TOTAL_SECTIONS package blocks from $YAML_FILE installed successfully."

# Ensure no background daemons are left hanging
pkill -9 gpg-agent || true
pkill -9 dirmngr || true
pkill -9 keyboxd || true
pkill -9 scdaemon || true
pkill -9 dbus-daemon || true
pkill -9 dbus-broker || true
pkill -9 gvfsd || true
pkill -9 dconf-service || true