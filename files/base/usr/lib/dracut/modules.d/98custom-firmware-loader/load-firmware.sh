#!/bin/sh

# Source dracut library if available
type getarg >/dev/null 2>&1 || . /lib/dracut-lib.sh

# Retrieve custom firmware command line arguments
FIRMWARE_DEV=$(getarg firmware.dev=)
FIRMWARE_PATH=$(getarg firmware.path=)

# If parameters are not specified, do nothing and exit
if [ -z "$FIRMWARE_DEV" ] || [ -z "$FIRMWARE_PATH" ]; then
    exit 0
fi

# Resolve the device node (e.g., UUID=xxx, LABEL=xxx, or direct path /dev/xxx)
DEV=$(findfs "$FIRMWARE_DEV" 2>/dev/null)
if [ -z "$DEV" ]; then
    # Fallback to blkid if findfs is not available or hasn't found the device yet
    case "$FIRMWARE_DEV" in
        UUID=*)
            DEV=$(blkid -U "${FIRMWARE_DEV#UUID=}" 2>/dev/null)
            ;;
        LABEL=*)
            DEV=$(blkid -L "${FIRMWARE_DEV#LABEL=}" 2>/dev/null)
            ;;
        /dev/*)
            DEV="$FIRMWARE_DEV"
            ;;
    esac
fi

# If device cannot be resolved, warn and exit
if [ -z "$DEV" ]; then
    warn "Custom Firmware Loader: Device '$FIRMWARE_DEV' could not be resolved."
    exit 0
fi

MNT="/tmp/firmware_mount"
mkdir -p "$MNT"

# Mount the device read-only to prevent any writes to the boot partition
if mount -o ro "$DEV" "$MNT" 2>/dev/null; then
    # Prevent path traversal attacks
    case "$FIRMWARE_PATH" in
        ../*|*/../*|*/..)
            warn "Custom Firmware Loader: Path traversal attempt detected in '$FIRMWARE_PATH'."
            ;;
        *)
            TARGET_PATH="$MNT/$FIRMWARE_PATH"
            if [ -d "$TARGET_PATH" ]; then
                # Copy directory contents recursively (preserves subdirectories like edid/, amdgpu/, etc.)
                mkdir -p /lib/firmware
                cp -R "$TARGET_PATH"/* /lib/firmware/ 2>/dev/null
                info "Custom Firmware Loader: Loaded firmware directory '$FIRMWARE_PATH' from '$FIRMWARE_DEV'"
            elif [ -f "$TARGET_PATH" ]; then
                # Copy a single file preserving its relative path structure
                REL_DIR=$(dirname "$FIRMWARE_PATH")
                mkdir -p "/lib/firmware/$REL_DIR"
                cp "$TARGET_PATH" "/lib/firmware/$REL_DIR/" 2>/dev/null
                info "Custom Firmware Loader: Loaded firmware file '$FIRMWARE_PATH' from '$FIRMWARE_DEV'"
            else
                warn "Custom Firmware Loader: Path '$FIRMWARE_PATH' not found on '$FIRMWARE_DEV'."
            fi
            ;;
    esac
    umount "$MNT" 2>/dev/null
else
    warn "Custom Firmware Loader: Failed to mount '$DEV' read-only."
fi

# Clean up mount point
rm -rf "$MNT" 2>/dev/null
