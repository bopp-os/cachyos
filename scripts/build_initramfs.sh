#!/bin/bash
# Regenerate module dependencies and the initramfs for the installed kernel, then tag
# /usr/lib/modules so chunkah splits it by how often each part changes.
set -eo pipefail

echo "::group::Building initramfs"

KERNEL_DIR="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d | sort -V | tail -n 1)"
if [ -z "$KERNEL_DIR" ] || [ ! -d "$KERNEL_DIR" ]; then
    echo "ERROR: Could not find kernel directory in /usr/lib/modules" >&2
    exit 1
fi
KERNEL_VER="$(basename "$KERNEL_DIR")"
echo "Target kernel version: $KERNEL_VER"

depmod -a "$KERNEL_VER"
find "$KERNEL_DIR" -maxdepth 1 -type f -name "modules.*" -exec touch -d "@${SOURCE_DATE_EPOCH:-0}" {} +
SOURCE_DATE_EPOCH=0 dracut --force --reproducible "$KERNEL_DIR/initramfs.img" "$KERNEL_VER"

# Stock modules and vmlinuz keep the linux-cachyos package tag from the ALPM hook.
# The initramfs embeds system state (groups, ld.so.cache, hwdb, os-release) and changes on
# most builds, so it gets its own component to avoid dragging the stock modules along.
find "$KERNEL_DIR" -maxdepth 1 -type f \( -name initramfs.img -o -name 'modules.*' \) \
    -exec setfattr -h -n user.component -v kernel-initramfs {} + \
    -exec setfattr -h -n user.update-interval -v daily {} +

# Out-of-tree modules from build_kernel_modules.sh
for dir in "$KERNEL_DIR/extra" "$KERNEL_DIR/updates"; do
    [ -d "$dir" ] || continue
    find "$dir" -type f \
        -exec setfattr -h -n user.component -v kernel-extra-modules {} + \
        -exec setfattr -h -n user.update-interval -v weekly {} +
done

# Anything else no package claimed (e.g. modules installed outside extra/ or updates/)
find /usr/lib/modules -type f -exec sh -c '
    for f; do
        getfattr -h -n user.component "$f" >/dev/null 2>&1 && continue
        setfattr -h -n user.component -v kernel-extra-modules "$f"
        setfattr -h -n user.update-interval -v weekly "$f"
    done' sh {} +

echo "::endgroup::"
