#!/bin/bash

while read -r pkgname; do
    # Query the package files, catching the exit code if pacman fails
    if ! file_list=$(pacman -Qlq "$pkgname" 2>/dev/null); then
        echo "Warning: Failed to query files for package '$pkgname'" >&2
        continue
    fi

    # Iterate over the captured file list
    while read -r filepath; do
        # Only target regular files (ignore symlinks and directories)
        if [[ -f "$filepath" && ! -L "$filepath" ]]; then
            # Group by COMPONENT_TAG if set, otherwise fallback to individual package names
            setfattr -n user.component -v "${COMPONENT_TAG:-$pkgname}" "$filepath"
            if [[ -n "$UPDATE_INTERVAL_TAG" ]]; then
                setfattr -n user.update-interval -v "$UPDATE_INTERVAL_TAG" "$filepath"
            fi
        fi
    done <<< "$file_list"
done
