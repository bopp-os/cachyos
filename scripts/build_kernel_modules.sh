#!/bin/bash
set -eo pipefail

echo "::group::Building Out-of-Tree Kernel Modules (DKMS-Free)"

# Configuration toggles (can be overridden via environment variables)
BUILD_NCT6687D="${BUILD_NCT6687D:-true}"
BUILD_IT87="${BUILD_IT87:-true}"
BUILD_XPADNEO="${BUILD_XPADNEO:-true}"

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
if [ "$BUILD_IT87" = "true" ]; then
    echo "--- Building it87 (ITE IT86xx/IT87xx Super I/O) ---"
    git clone --depth 1 https://github.com/frankcrawford/it87.git "$BUILD_WORK_DIR/it87"
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS modules
    make -C "$KBUILD_DIR" M="$BUILD_WORK_DIR/it87" $LLVM_FLAGS INSTALL_MOD_DIR="extra" modules_install
    echo "it87 installed."
fi

# 6. Build xpadneo (Xbox One/Series Bluetooth controller driver)
if [ "$BUILD_XPADNEO" = "true" ]; then
    echo "--- Building xpadneo (Xbox Wireless Bluetooth) ---"
    git clone --depth 1 https://github.com/atar-axis/xpadneo.git "$BUILD_WORK_DIR/xpadneo"
    make -C "$BUILD_WORK_DIR/xpadneo/hid-xpadneo" KERNEL_SOURCE_DIR="$KBUILD_DIR" $LLVM_FLAGS modules
    make -C "$BUILD_WORK_DIR/xpadneo/hid-xpadneo" KERNEL_SOURCE_DIR="$KBUILD_DIR" $LLVM_FLAGS modules_install

    # Install udev rules for xpadneo permissions
    if [ -f "$BUILD_WORK_DIR/xpadneo/hid-xpadneo/etc-udev-rules.d/99-xpadneo.rules" ]; then
        mkdir -p /usr/lib/udev/rules.d
        cp "$BUILD_WORK_DIR/xpadneo/hid-xpadneo/etc-udev-rules.d/99-xpadneo.rules" /usr/lib/udev/rules.d/99-xpadneo.rules
    fi
    echo "xpadneo installed."
fi

# 7. Ensure module compression matches existing kernel modules
if find "$KERNEL_DIR" -name "*.ko.zst" 2>/dev/null | grep -q .; then
    echo "Compressing any uncompressed .ko modules in extra/ with zstd..."
    find "$KERNEL_DIR/extra" -type f -name "*.ko" -exec zstd -T0 --rm -f {} + 2>/dev/null || true
fi

# 8. Clean up workspace and temporary build dependencies
rm -rf "$BUILD_WORK_DIR"

if [ ${#BUILD_DEPS[@]} -gt 0 ]; then
    echo "Removing temporary build dependencies: ${BUILD_DEPS[*]}"
    pacman -Rns --noconfirm "${BUILD_DEPS[@]}" || true
fi

echo "Out-of-tree kernel modules build completed successfully."
echo "::endgroup::"
