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
    pacman -Sy --noconfirm --needed "${BUILD_DEPS[@]}"
fi

# Create temporary workspace for module source trees
BUILD_WORK_DIR="/tmp/extra-kmods"
rm -rf "$BUILD_WORK_DIR"
mkdir -p "$BUILD_WORK_DIR"

# 4. Build nct6687d (Nuvoton NCT6686D / NCT6687D Super I/O)
if [ "$BUILD_NCT6687D" = "true" ]; then
    echo "--- Building nct6687d (Nuvoton NCT6686D/NCT6687D) ---"
    git clone --depth 1 https://github.com/Fred78290/nct6687d.git "$BUILD_WORK_DIR/nct6687d"
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/nct6687d" $LLVM_FLAGS modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/nct6687d" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install
    echo "nct6687d installed."
fi

# 5. Build it87 (ITE IT86xx / IT87xx Super I/O for Gigabyte/ASUS)
# Installed to "updates" (not "extra") so it takes precedence over the in-tree it87 module;
# Arch's depmod search order is "updates extramodules built-in" and "extra" counts as built-in.
if [ "$BUILD_IT87" = "true" ]; then
    echo "--- Building it87 (ITE IT86xx/IT87xx Super I/O) ---"
    git clone --depth 1 https://github.com/frankcrawford/it87.git "$BUILD_WORK_DIR/it87"
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS INSTALL_MOD_DIR="updates" modules_install
    echo "it87 installed."
fi

# 6. Build xpadneo (Xbox One/Series Bluetooth controller driver)
if [ "$BUILD_XPADNEO" = "true" ]; then
    echo "--- Building xpadneo (Xbox Wireless Bluetooth) ---"
    git clone --depth 1 https://github.com/atar-axis/xpadneo.git "$BUILD_WORK_DIR/xpadneo"
    
    # xpadneo Makefile expects a VERSION file; on shallow clones git describe fails, so provide a fallback
    XPADNEO_VER="$(git -C "$BUILD_WORK_DIR/xpadneo" describe --tags 2>/dev/null || echo "v0.10.4")"
    echo "$XPADNEO_VER" > "$BUILD_WORK_DIR/xpadneo/VERSION"

    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/xpadneo/hid-xpadneo/src" $LLVM_FLAGS VERSION="$XPADNEO_VER" modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/xpadneo/hid-xpadneo/src" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install

    # Install udev rules for xpadneo
    if [ -d "$BUILD_WORK_DIR/xpadneo/hid-xpadneo/etc-udev-rules.d" ]; then
        mkdir -p /usr/lib/udev/rules.d
        cp "$BUILD_WORK_DIR/xpadneo/hid-xpadneo/etc-udev-rules.d/"*.rules /usr/lib/udev/rules.d/
    fi
    echo "xpadneo installed."
fi

# Optional modules below are non-fatal: a build failure emits a CI warning and the image ships without that module.
# Each step is chained with "|| return 1" because set -e is ignored inside functions called from an "||" list.

# 7. Build xone (Xbox One/Series wireless dongle and wired accessories)
# Uses the OpenGamingCollective fork, which coexists with the in-tree xpad driver.
# Dongle firmware comes from the xone-dongle-firmware package; mt76x2u is blacklisted via /usr/lib/modprobe.d/xone.conf.
build_xone() {
    git clone --depth 1 https://github.com/OpenGamingCollective/xonedo.git "$BUILD_WORK_DIR/xone" || return 1

    # xone sources carry a #VERSION# placeholder normally filled in by its install.sh
    local ver
    ver="$(git -C "$BUILD_WORK_DIR/xone" describe --tags 2>/dev/null || echo "v0.5.7-ogc1")"
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
    git clone --depth 1 https://github.com/BoukeHaarsma23/zenergy.git "$BUILD_WORK_DIR/zenergy" || return 1
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/zenergy" $LLVM_FLAGS modules || return 1
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/zenergy" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install || return 1
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
