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

echo "Sanitizing unassigned build-time UIDs in /var..."
find /var -mindepth 1 -exec sh -c '
  for target; do
    owner=$(stat -c "%U" "$target" 2>/dev/null || echo "")
    if [ -n "$owner" ] && ! id -u "$owner" >/dev/null 2>&1; then
      chown root:root "$target" 2>/dev/null || true
    fi
  done
' sh {} +

echo "Generating tmpfiles for /var..."
> /usr/lib/tmpfiles.d/99-boppos-var-auto.conf

find /var -mindepth 1 -type d -not -path "/var/tmp*" -not -path "/var/cache*" -not -path "/var/log*" 2>/dev/null | while read -r dir; do
    if [ -L "$dir" ]; then continue; fi
    mode=$(stat -c "%a" "$dir")
    if [ ${#mode} -eq 3 ]; then mode="0$mode"; fi
    owner=$(stat -c "%U" "$dir")
    group=$(stat -c "%G" "$dir")
    if ! id -u "$owner" >/dev/null 2>&1; then owner="root"; fi
    if ! getent group "$group" >/dev/null 2>&1; then group="root"; fi
    echo "d $dir $mode $owner $group - -" >> /usr/lib/tmpfiles.d/99-boppos-var-auto.conf
done

echo "Recreating essential directories for bootc..."
mkdir -p /var /boot /sysroot

echo "Setting up SDDM themes default backup directory..."
mkdir -p /usr/share/sddm/themes-default
if [ -d /usr/share/sddm/themes ] && [ ! -L /usr/share/sddm/themes ]; then
    cp -a /usr/share/sddm/themes/* /usr/share/sddm/themes-default/ 2>/dev/null || true
fi

echo "Cleaning machine-id and build-time state..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id /etc/random-seed

echo "Purging transient pacman databases and logs..."
rm -rf /var/lib/pacman/sync/* /usr/lib/sysimage/sync/* /var/log/pacman.log 2>/dev/null || true

echo "Cleaning /run and /tmp..."
rm -rf /run/* /run/.[!.]* /tmp/* /tmp/.[!.]* 2>/dev/null || true

echo "Running bootc container lint to verify cleanup..."
bootc container lint