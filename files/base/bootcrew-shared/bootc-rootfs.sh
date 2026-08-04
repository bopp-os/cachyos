#!/usr/bin/env bash

set -xeuo pipefail

# Safely remove directories without attempting to rm -rf mounted volume paths
for dir in /boot /home /root /usr/local /srv /opt /mnt /usr/lib/sysimage/log /usr/lib/sysimage/cache/pacman/pkg; do
    rm -rf "$dir" 2>/dev/null || true
done

# Clean /var subdirectories excluding mounted pacman cache
if [ -d /var ]; then
    find /var -mindepth 1 -maxdepth 1 ! -name 'cache' -exec rm -rf {} + 2>/dev/null || true
    if [ -d /var/cache ]; then
        find /var/cache -mindepth 1 -maxdepth 1 ! -name 'pacman' -exec rm -rf {} + 2>/dev/null || true
    fi
fi

mkdir -p /sysroot /boot /usr/lib/ostree /var /var/lib /usr/lib/sysimage/lib/pacman
ln -sf /usr/lib/sysimage/lib/pacman /var/lib/pacman

ln -sT sysroot/ostree /ostree && ln -sT var/roothome /root && ln -sT var/srv /srv && ln -sT var/opt /opt && ln -sT var/mnt /mnt && ln -sT var/home /home && ln -sT ../var/usrlocal /usr/local

echo "$(for dir in opt home srv mnt usrlocal ; do echo "d /var/$dir 0755 root root -" ; done)" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

printf "d /var/roothome 0700 root root -\nd /run/media 0755 root root -" | tee -a "/usr/lib/tmpfiles.d/bootc-base-dirs.conf"

printf '[composefs]\nenabled = yes\n[sysroot]\nreadonly = true\n' | tee "/usr/lib/ostree/prepare-root.conf"

