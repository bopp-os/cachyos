#!/bin/bash
set -eo pipefail

echo "::group::Building Out-of-Tree Kernel Modules (DKMS-Free)"

# Configuration toggles (can be overridden via environment variables)
BUILD_NCT6687D="${BUILD_NCT6687D:-true}"
BUILD_IT87="${BUILD_IT87:-true}"
BUILD_XPADNEO="${BUILD_XPADNEO:-true}"
BUILD_XONE="${BUILD_XONE:-true}"
BUILD_ZENERGY="${BUILD_ZENERGY:-true}"

# 1. Detect target kernel directory and headers
KERNEL_DIR="$(find /usr/lib/modules -maxdepth 1 -type d | grep -v -E '\.img$' | sort -V | tail -n 1)"
if [ -z "$KERNEL_DIR" ] || [ ! -d "$KERNEL_DIR" ]; then
    echo "ERROR: Could not find kernel directory in /usr/lib/modules" >&2
    exit 1
fi

KERNEL_VER="$(basename "$KERNEL_DIR")"
KBUILD_DIR="$KERNEL_DIR/build"

if [ ! -d "$KBUILD_DIR" ]; then
    echo "ERROR: Kernel build tree $KBUILD_DIR not found. Ensure kernel headers package is installed." >&2
    exit 1
fi

echo "Target kernel version: $KERNEL_VER"
echo "Target kernel directory: $KERNEL_DIR"
echo "Target kernel build tree: $KBUILD_DIR"

# 2. Detect Clang / LLVM compiler flags matching kernel build
LLVM_FLAGS=""
if grep -qs "CONFIG_CC_IS_CLANG=y" "$KBUILD_DIR/.config"; then
    echo "Kernel was compiled with Clang/LLVM. Setting LLVM=1"
    LLVM_FLAGS="LLVM=1"
fi

# 3. Ensure required build tools are installed
BUILD_DEPS=()
for pkg in git make gcc clang llvm lld zstd; do
    if ! pacman -Q "$pkg" &>/dev/null; then
        BUILD_DEPS+=("$pkg")
    fi
done

if [ ${#BUILD_DEPS[@]} -gt 0 ]; then
    echo "Installing temporary build dependencies: ${BUILD_DEPS[*]}"
    # No -y: the databases are the ones prefetch saved, so these are the packages it already downloaded and scanned
    pacman -S --noconfirm --needed "${BUILD_DEPS[@]}"
fi

# Create temporary workspace for module source trees
BUILD_WORK_DIR="/tmp/extra-kmods"
rm -rf "$BUILD_WORK_DIR"
mkdir -p "$BUILD_WORK_DIR"

# Module sources come from what the prefetch step saved and ClamAV-scanned (prefetch_extras.sh); the build has no
# network. Both kinds are pinned in kmod_sources.sh. ALLOW_NETWORK_BUILD=1 fetches them instead, for local builds
# without a prefetched cache.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=kmod_sources.sh
source "$SCRIPT_DIR/kmod_sources.sh"
KMOD_SRC_DIR="${KMOD_SRC_DIR:-/var/cache/pacman/pkg/.src}"
PKG_CACHE_DIR="${PKG_CACHE_DIR:-$(dirname "$KMOD_SRC_DIR")}"

# Source of a module in KMOD_REPOS, at its pinned commit
fetch_kmod_src() {
    local name=$1 dest=$2
    local pinned=${KMOD_COMMITS[$name]} saved
    if [ -f "$KMOD_SRC_DIR/$name.tar" ]; then
        saved="$(cut -d' ' -f1 "$KMOD_SRC_DIR/$name.commit" 2>/dev/null || true)"
        if [ "$saved" != "$pinned" ]; then
            echo "ERROR: prefetched $name source is commit ${saved:-unknown}, but kmod_sources.sh pins $pinned" >&2
            return 1
        fi
        echo "Using prefetched $name source at pinned commit $pinned"
        mkdir -p "$dest" && tar -xf "$KMOD_SRC_DIR/$name.tar" -C "$dest"
    elif [ -n "${ALLOW_NETWORK_BUILD:-}" ]; then
        kmod_fetch_commit "$name" "$dest"
    else
        echo "ERROR: prefetched source $KMOD_SRC_DIR/$name.tar not found (set ALLOW_NETWORK_BUILD=1 to fetch instead)" >&2
        return 1
    fi
}

# Unpacks the CachyOS package of a module in KMOD_PACKAGES into $2 and prints the one source folder under usr/src.
# pacman -Sw checks the package's signature first (the copy prefetch left in the cache; with ALLOW_NETWORK_BUILD it
# may download it), so nothing is read from a package pacman did not verify.
fetch_kmod_package() {
    local name=$1 dest=$2
    local pkg=${KMOD_PACKAGES[$name]} file srcs
    pacman -Swdd --noconfirm --cachedir "$PKG_CACHE_DIR" "$pkg" >&2 || return 1
    file="$PKG_CACHE_DIR/$(pacman -Sddp --print-format '%f' "$pkg")" || return 1
    echo "Using $name source from $(basename "$file")" >&2
    mkdir -p "$dest" && bsdtar -xf "$file" -C "$dest" usr || return 1
    shopt -s nullglob
    srcs=("$dest"/usr/src/*/)
    shopt -u nullglob
    if [ ${#srcs[@]} -ne 1 ]; then
        echo "ERROR: expected one source folder under usr/src in $(basename "$file"), found ${#srcs[@]}" >&2
        return 1
    fi
    echo "${srcs[0]%/}"
}

# 4. Build nct6687d (Nuvoton NCT6686D / NCT6687D Super I/O)
if [ "$BUILD_NCT6687D" = "true" ]; then
    echo "--- Building nct6687d (Nuvoton NCT6686D/NCT6687D) ---"
    fetch_kmod_src nct6687d "$BUILD_WORK_DIR/nct6687d"
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/nct6687d" $LLVM_FLAGS modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/nct6687d" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install
    echo "nct6687d installed."
fi

# 5. Build it87 (ITE IT86xx / IT87xx Super I/O for Gigabyte/ASUS)
# Installed to "updates" (not "extra") so it takes precedence over the in-tree it87 module;
# Arch's depmod search order is "updates extramodules built-in" and "extra" counts as built-in.
if [ "$BUILD_IT87" = "true" ]; then
    echo "--- Building it87 (ITE IT86xx/IT87xx Super I/O) ---"
    fetch_kmod_src it87 "$BUILD_WORK_DIR/it87"
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS INSTALL_MOD_DIR="updates" modules_install
    echo "it87 installed."
fi

# 6. Build xpadneo (Xbox One/Series Bluetooth controller driver)
if [ "$BUILD_XPADNEO" = "true" ]; then
    echo "--- Building xpadneo (Xbox Wireless Bluetooth) ---"
    # The package's source folder is usr/src/hid-xpadneo-<version>; the version goes into the module, as dkms does.
    XPADNEO_SRC="$(fetch_kmod_package xpadneo "$BUILD_WORK_DIR/xpadneo")"
    XPADNEO_VER="${XPADNEO_SRC##*/hid-xpadneo-}"

    make -C "$KBUILD_DIR" M="$XPADNEO_SRC/src" $LLVM_FLAGS VERSION="$XPADNEO_VER" modules
    make -C "$KBUILD_DIR" M="$XPADNEO_SRC/src" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install

    # The udev rules and modprobe aliases the package installs next to its source
    mkdir -p /usr/lib/udev/rules.d /usr/lib/modprobe.d
    cp "$BUILD_WORK_DIR/xpadneo/usr/lib/udev/rules.d/"*.rules /usr/lib/udev/rules.d/
    cp "$BUILD_WORK_DIR/xpadneo/usr/lib/modprobe.d/xpadneo.conf" /usr/lib/modprobe.d/
    echo "xpadneo $XPADNEO_VER installed."
fi

# Optional modules below are non-fatal: a build failure emits a CI warning and the image ships without that module.
# Each step is chained with "|| return 1" because set -e is ignored inside functions called from an "||" list.

# 7. Build xone (Xbox One/Series wireless dongle and wired accessories)
# Uses the OpenGamingCollective fork, which coexists with the in-tree xpad driver.
# Dongle firmware comes from the xone-dongle-firmware package; mt76x2u is blacklisted via /usr/lib/modprobe.d/xone.conf.
build_xone() {
    fetch_kmod_src xone "$BUILD_WORK_DIR/xone" || return 1

    # xone sources carry a #VERSION# placeholder normally filled in by its install.sh
    local ver=${KMOD_VERSIONS[xone]}
    find "$BUILD_WORK_DIR/xone" -type f -name '*.c' -exec sed -i "s/#VERSION#/${ver#v}/" {} + || return 1

    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/xone" $LLVM_FLAGS modules || return 1
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/xone" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install || return 1
}

if [ "$BUILD_XONE" = "true" ]; then
    echo "--- Building xone (Xbox Wireless dongle) ---"
    if build_xone; then
        echo "xone installed."
    else
        echo "::warning::xone build failed, skipping"
    fi
fi

# 8. Build zenergy (AMD Zen CPU energy readings via hwmon, readable without root)
# Loaded after k10temp on AMD systems via the softdep in /usr/lib/modprobe.d/zenergy.conf.
build_zenergy() {
    local src
    src="$(fetch_kmod_package zenergy "$BUILD_WORK_DIR/zenergy")" || return 1
    make -C "$KBUILD_DIR" M="$src" $LLVM_FLAGS modules || return 1
    make -C "$KBUILD_DIR" M="$src" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install || return 1
}

if [ "$BUILD_ZENERGY" = "true" ]; then
    echo "--- Building zenergy (AMD Zen energy monitoring) ---"
    if build_zenergy; then
        echo "zenergy installed."
    else
        echo "::warning::zenergy build failed, skipping"
    fi
fi

# 9. Ensure module compression matches existing kernel modules
if find "$KERNEL_DIR" -name "*.ko.zst" 2>/dev/null | grep -q .; then
    echo "Compressing any uncompressed .ko modules with zstd..."
    find "$KERNEL_DIR/extra" "$KERNEL_DIR/updates" "$KERNEL_DIR/kernel/drivers/hid" -type f -name "*.ko" 2>/dev/null -exec zstd -T0 --rm -f {} + 2>/dev/null || true
fi

# 10. Clean up workspace and temporary build dependencies
rm -rf "$BUILD_WORK_DIR"

if [ ${#BUILD_DEPS[@]} -gt 0 ]; then
    echo "Removing temporary build dependencies: ${BUILD_DEPS[*]}"
    pacman -Rns --noconfirm "${BUILD_DEPS[@]}" || true
fi

echo "Out-of-tree kernel modules build completed successfully."
echo "::endgroup::"
