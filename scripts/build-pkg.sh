#!/bin/bash

# Ensure cache directories exist and are accessible by builduser
sudo mkdir -p /var/cache/makepkg/src /var/cache/makepkg/ccache /var/cache/makepkg/sccache /var/cache/makepkg/go-build /var/cache/makepkg/go-mod
sudo chown -R builduser:builduser /var/cache/makepkg

export SRCDEST=/var/cache/makepkg/src
export CCACHE_DIR=/var/cache/makepkg/ccache
export CCACHE_MAXSIZE=2G
export SCCACHE_DIR=/var/cache/makepkg/sccache
export SCCACHE_CACHE_SIZE=2G
export RUSTC_WRAPPER=/usr/bin/sccache
export GOCACHE=/var/cache/makepkg/go-build
export GOMODCACHE=/var/cache/makepkg/go-mod

if [ "$VERBOSE" = "true" ]; then
    sudo -E -u builduser PKGDEST=/home/builduser/packages SRCDEST=$SRCDEST CCACHE_DIR=$CCACHE_DIR SCCACHE_DIR=$SCCACHE_DIR RUSTC_WRAPPER=$RUSTC_WRAPPER GOCACHE=$GOCACHE GOMODCACHE=$GOMODCACHE makepkg --noconfirm -s --skipinteg -c
else
    if ! sudo -E -u builduser PKGDEST=/home/builduser/packages SRCDEST=$SRCDEST CCACHE_DIR=$CCACHE_DIR SCCACHE_DIR=$SCCACHE_DIR RUSTC_WRAPPER=$RUSTC_WRAPPER GOCACHE=$GOCACHE GOMODCACHE=$GOMODCACHE makepkg --noconfirm -s --skipinteg -c > /tmp/makepkg.log 2>&1; then
        echo "::error title=AUR Build Failed::Makepkg encountered an error while building a package!"
        echo -e "\n================ MAKEPKG LOG ================"
        cat /tmp/makepkg.log
        echo -e "=============================================\n"
        exit 1
    fi
fi