#!/bin/bash
# Rank mirrors with CachyOS's own cachyos-rate-mirrors wrapper and copy cachyos[-v3|-v4]-mirrorlist
# to the output directory. The wrapper and the static rate-mirrors binary are downloaded directly
# (pinned by checksum) instead of "pacman -Sy cachyos-rate-mirrors", so rating still works when a
# mirror serves a bad repo database. Falls back to the image's default lists.
set -eo pipefail

OUT_DIR="${1:-/workspace-mirrors}"

# Wrapper from CachyOS-PKGBUILDS (same file as the cachyos-rate-mirrors 24-1 package)
WRAPPER_COMMIT="abc9145fcfb00302831ffbf6399782c9ee64917f"
WRAPPER_SHA256="47eff7dd429e17b5445f3b47c46bdc51aa6145496d82650b46420310d9b1dcc0"
RATE_MIRRORS_VERSION="v0.33.0"
RATE_MIRRORS_SHA256="e0ffb221649b7e1ce6b67ffaabe7cfd2b619c8bf8d6971e07ff9507d4e19a4b3"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

rate() {
    local name="rate-mirrors-${RATE_MIRRORS_VERSION}-x86_64-unknown-linux-musl"
    curl -fsSL --retry 3 --max-time 60 -o "$WORK_DIR/rm.tar.gz" \
        "https://github.com/westandskif/rate-mirrors/releases/download/${RATE_MIRRORS_VERSION}/${name}.tar.gz" || return 1
    echo "${RATE_MIRRORS_SHA256}  $WORK_DIR/rm.tar.gz" | sha256sum -c - || return 1
    tar -xzf "$WORK_DIR/rm.tar.gz" -C "$WORK_DIR" || return 1
    mkdir -p "$WORK_DIR/bin"
    install -m 0755 "$WORK_DIR/$name/rate_mirrors" "$WORK_DIR/bin/rate-mirrors" || return 1

    curl -fsSL --retry 3 --max-time 60 -o "$WORK_DIR/bin/cachyos-rate-mirrors" \
        "https://raw.githubusercontent.com/CachyOS/CachyOS-PKGBUILDS/${WRAPPER_COMMIT}/cachyos-rate-mirrors/cachyos-rate-mirrors" || return 1
    echo "${WRAPPER_SHA256}  $WORK_DIR/bin/cachyos-rate-mirrors" | sha256sum -c - || return 1
    chmod +x "$WORK_DIR/bin/cachyos-rate-mirrors"

    # Rewrites the lists in /etc/pacman.d in place; they are left untouched if it fails early
    PATH="$WORK_DIR/bin:$PATH" timeout 240 cachyos-rate-mirrors < /dev/null
}

if rate; then
    echo "Mirror rating complete. Top mirrors:"
    grep '^Server = ' /etc/pacman.d/cachyos-mirrorlist | head -5
else
    echo "::warning::Mirror rating failed, falling back to the image's default mirrorlists"
fi

mkdir -p "$OUT_DIR"
cp /etc/pacman.d/cachyos*-mirrorlist "$OUT_DIR/"
