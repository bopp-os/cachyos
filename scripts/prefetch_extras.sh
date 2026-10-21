#!/bin/bash
# Downloads what the offline builds need that is not a pacman package, into hidden folders of the package cache:
#   .bootstrap/flathub.flatpakrepo   Flathub remote definition for flatpak remote-add
#   .src/<module>.tar                latest commit of each kernel module repo (git archive, no .git)
#   .src/<module>.commit             the commit hash and URL it came from
#   .src/<module>.describe           "git describe --tags" of that commit, when the shallow clone has a tag
# Runs in the prefetch step, which has network access. The tarballs are ClamAV-scanned with the packages.
#
# Usage: prefetch_extras.sh [cache_dir]
set -euo pipefail

CACHE_DIR="${1:-/var/cache/pacman/pkg}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=kmod_sources.sh
source "$SCRIPT_DIR/kmod_sources.sh"

mkdir -p "$CACHE_DIR/.bootstrap" "$CACHE_DIR/.src"

echo "Downloading the Flathub remote definition..."
curl -fsSL --retry 5 --retry-delay 5 --retry-connrefused --max-time 60 \
    -o "$CACHE_DIR/.bootstrap/flathub.flatpakrepo.tmp" https://flathub.org/repo/flathub.flatpakrepo
mv -f "$CACHE_DIR/.bootstrap/flathub.flatpakrepo.tmp" "$CACHE_DIR/.bootstrap/flathub.flatpakrepo"

# Sources from a previous run are dropped, so a repo that fails to clone now is missing rather than stale.
rm -f "$CACHE_DIR/.src/"*
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
for name in "${!KMOD_REPOS[@]}"; do
    url="${KMOD_REPOS[$name]}"
    echo "Fetching kernel module source $name from $url..."
    # A failed clone is not fatal here: build_kernel_modules.sh decides which modules are required.
    if ! git clone --quiet --depth 1 "$url" "$WORK_DIR/$name"; then
        echo "::warning::Could not clone $url; the $name module source is not available to the build"
        continue
    fi
    git -C "$WORK_DIR/$name" archive --format=tar -o "$CACHE_DIR/.src/$name.tar" HEAD
    echo "$(git -C "$WORK_DIR/$name" rev-parse HEAD) $url" > "$CACHE_DIR/.src/$name.commit"
    git -C "$WORK_DIR/$name" describe --tags 2>/dev/null > "$CACHE_DIR/.src/$name.describe" || true
    echo "  $name: $(cut -d' ' -f1 "$CACHE_DIR/.src/$name.commit")"
done
