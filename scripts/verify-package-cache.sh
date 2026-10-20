#!/bin/bash
# Fails if the package cache holds an archive that clamscan-prefetch.sh did not scan clean.
#
# Packages should only be downloaded in the prefetch step. Run after a build, this catches any pacman call that still
# reached the network and put a package into the cache after the ClamAV scan: its name + SHA-256 is not in the record.
#
# Usage: verify-package-cache.sh <cache_dir>
set -euo pipefail

CACHE_DIR=$(readlink -f "${1:?usage: verify-package-cache.sh <cache_dir>}")
RECORD="$(dirname "$CACHE_DIR")/.clamav_scan_cache"

echo "::group::Verifying every cached package was scanned by ClamAV"
if [ ! -f "$RECORD" ]; then
  echo "::endgroup::"
  echo "::error::No ClamAV scan record at $RECORD; the ClamAV scan step did not run or did not finish."
  exit 1
fi

# The record holds "<sha256> <package file name>" lines (and image entries, which never match a file here).
declare -A CLEAN=()
while IFS=' ' read -r hash name; do
  [[ -n "$hash" && -n "$name" ]] && CLEAN["$hash $name"]=1
done < "$RECORD"

TOTAL=0
UNSCANNED=()
while IFS= read -r line; do
  hash=${line%% *}
  name=$(basename "${line#*  }")
  TOTAL=$((TOTAL + 1))
  [[ -n "${CLEAN["$hash $name"]:-}" ]] || UNSCANNED+=("$name")
done < <(find "$CACHE_DIR" -maxdepth 1 -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) -print0 \
  | xargs -0 -r sha256sum)
echo "::endgroup::"

if [ ${#UNSCANNED[@]} -gt 0 ]; then
  for name in "${UNSCANNED[@]}"; do
    echo "::error::Package in the cache was not scanned by ClamAV: $name"
  done
  echo "::error::${#UNSCANNED[@]} of $TOTAL cached packages were added or changed after the ClamAV scan, so a pacman call in the build used the network. Re-running the workflow scans them; if it keeps happening, find which step downloads them."
  exit 1
fi
echo "✅ All $TOTAL cached packages were scanned clean by ClamAV."
