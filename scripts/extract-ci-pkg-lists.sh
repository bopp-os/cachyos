#!/bin/bash
set -euo pipefail

mkdir -p build/
ALL_PKGS="build/all-packages.txt"
CACHY_PKGS="build/cachyos-packages.txt"

echo "Generating package lists..."

# 1. Get all installed packages
pacman -Qq > "$ALL_PKGS"

# 2. Find packages sourced from CachyOS repos
# pacman -Sl lists all packages in synced repos: "<repo> <pkgname> <version> [installed]"
# We filter for lines with "[installed]" and where the repo name contains "cachyos"
pacman -Sl | awk '/\[installed\]/ && $1 ~ /cachyos/ {print $2}' | sort | uniq > "$CACHY_PKGS" || true

# 3. Find AUR and foreign packages (not in any sync database)
AUR_PKGS="build/aur-packages.txt"
pacman -Qm | awk '{print $1}' > "$AUR_PKGS" || true

ALL_COUNT=$(wc -l < "$ALL_PKGS")
CACHY_COUNT=$(wc -l < "$CACHY_PKGS")
AUR_COUNT=$(wc -l < "$AUR_PKGS")

echo "Total installed packages: $ALL_COUNT" >&2
echo "CachyOS specific packages: $CACHY_COUNT" >&2
echo "AUR/Foreign packages: $AUR_COUNT" >&2

echo "Package lists written to $ALL_PKGS, $CACHY_PKGS, and $AUR_PKGS."