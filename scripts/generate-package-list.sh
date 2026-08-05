#!/bin/bash
set -euo pipefail

DEST_DIR="/usr/share/boppos"
mkdir -p "$DEST_DIR" build/
JSON_FILE="$DEST_DIR/packages.json"
ALL_PKGS="build/all-packages.txt"
CACHY_PKGS="build/cachyos-packages.txt"
BOPP_PKGS="build/boppos-packages.txt"

echo "Generating package list from pacman database..."

# 1. Generate /usr/share/boppos/packages.json for GitHub Actions & artifact workflows
if command -v jq >/dev/null 2>&1; then
    pacman -Q | awk '{print "{\"name\":\"" $1 "\",\"version\":\"" $2 "\"}"}' | jq -s '.' > "$JSON_FILE"
else
    # Fallback if jq is not available during build
    echo "[" > "$JSON_FILE"
    pacman -Q | awk 'NR>1 {print ","} {print "  {\"name\":\"" $1 "\",\"version\":\"" $2 "\"}"}' >> "$JSON_FILE"
    echo "]" >> "$JSON_FILE"
fi

# 2. Get all installed packages
pacman -Qq > "$ALL_PKGS" 2>/dev/null || true

# 3. Find packages sourced from CachyOS repos
pacman -Sl 2>/dev/null | awk '/\[installed\]/ && $1 ~ /cachyos/ {print $2}' | sort | uniq > "$CACHY_PKGS" || true

# 4. Find packages sourced from bopp-os repo
pacman -Sl 2>/dev/null | awk '/\[installed\]/ && $1 ~ /bopp-os/ {print $2}' | sort | uniq > "$BOPP_PKGS" || true

ALL_COUNT=$(wc -l < "$ALL_PKGS" 2>/dev/null || echo 0)
CACHY_COUNT=$(wc -l < "$CACHY_PKGS" 2>/dev/null || echo 0)
BOPP_COUNT=$(wc -l < "$BOPP_PKGS" 2>/dev/null || echo 0)

echo "Package list generated at $JSON_FILE"
echo "Total installed packages: $ALL_COUNT" >&2
echo "CachyOS specific packages: $CACHY_COUNT" >&2
echo "Bopp-OS specific packages: $BOPP_COUNT" >&2