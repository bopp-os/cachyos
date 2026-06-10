#!/bin/bash
# Universal cleanup script for bootc images to pass linting.
#
# This script is designed to be run as the final step in a Containerfile
# for a bootc-based image. It performs two main functions:
#
# 1. var-tmpfiles: It scans the /var directory for any directories created
#    by package installations and dynamically generates a systemd-tmpfiles.d
#    configuration. This ensures that these stateful directories are correctly
#    re-created on the first boot of a deployed system, satisfying the
#    `var-tmpfiles` lint check.
#
# 2. nonempty-run-tmp: It cleans out the contents of /run and /tmp, which
#    are often polluted with transient files by package manager hooks and
#    other build-time processes. This satisfies the `nonempty-run-tmp`
#    lint check.

set -e

echo "Generating tmpfiles for /var..."
> /usr/lib/tmpfiles.d/99-boppos-var-auto.conf

find /var -mindepth 1 -type d -not -path "/var/tmp*" -not -path "/var/cache*" -not -path "/var/log*" 2>/dev/null | while read -r dir; do
    if [ -L "$dir" ]; then continue; fi
    mode=$(stat -c "%a" "$dir")
    if [ ${#mode} -eq 3 ]; then mode="0$mode"; fi
    echo "d $dir $mode $(stat -c "%U %G" "$dir") - -" >> /usr/lib/tmpfiles.d/99-boppos-var-auto.conf
done

echo "Recreating essential directories for bootc..."
mkdir -p /var /boot /sysroot

echo "Cleaning /run and /tmp..."
rm -rf /run/* /run/.[!.]* /tmp/* /tmp/.[!.]* 2>/dev/null || true

echo "Running bootc container lint to verify cleanup..."
bootc container lint