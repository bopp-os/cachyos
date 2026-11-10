#!/bin/bash
# Downloads what the offline builds need that is not a pacman package, into hidden folders of the package cache:
#   .bootstrap/flathub.flatpakrepo   Flathub remote definition for flatpak remote-add
#   .src/<module>.tar                the pinned commit of each kernel module repo in KMOD_COMMITS (git archive, no .git)
#   .src/<module>.commit             the commit hash and URL it came from
# It also downloads the CachyOS -dkms packages in KMOD_PACKAGES into the cache itself (without their dependencies);
# the build takes those modules' source out of them.
# Runs in the prefetch step, which has network access. The tarballs and packages are ClamAV-scanned with the others.
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
    echo "Fetching kernel module source $name at ${KMOD_COMMITS[$name]} from $url..."
    # A failed fetch is not fatal here: build_kernel_modules.sh decides which modules are required.
    if ! kmod_fetch_commit "$name" "$WORK_DIR/$name"; then
        echo "::warning::Could not fetch the pinned $name commit; the $name module source is not available to the build"
        continue
    fi
    git -C "$WORK_DIR/$name" archive --format=tar -o "$CACHE_DIR/.src/$name.tar" HEAD
    echo "${KMOD_COMMITS[$name]} $url" > "$CACHE_DIR/.src/$name.commit"
done

echo "Downloading kernel module source packages: ${KMOD_PACKAGES[*]}..."
# -dd: only these packages, not dkms and the rest of their dependencies; the build only reads the source out of them.
if ! pacman -Swdd --noconfirm --cachedir "$CACHE_DIR" "${KMOD_PACKAGES[@]}"; then
    echo "::warning::Could not download ${KMOD_PACKAGES[*]}; those module sources are not available to the build"
fi
