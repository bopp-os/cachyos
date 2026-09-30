#!/usr/bin/env bash
# Stop, disable and remove the steamvr-busname-fix systemd user service.
set -euo pipefail

readonly NAME=steamvr-busname-fix
readonly UNIT=$NAME.service
bin_dir=$HOME/.local/bin
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

die() {
    printf 'uninstall.sh: %s\n' "$*" >&2
    exit 1
}

((EUID != 0)) || die "run this as your normal user, not as root or with sudo"
systemctl --user show-environment >/dev/null 2>&1 ||
    die "can't reach your systemd user manager (systemctl --user); run this from your desktop session"

if systemctl --user cat "$UNIT" >/dev/null 2>&1; then
    systemctl --user disable --now "$UNIT"
else
    echo "$UNIT is not installed; removing any leftover files"
fi
rm -fv "$bin_dir/$NAME" "$unit_dir/$UNIT"
systemctl --user daemon-reload
systemctl --user reset-failed "$UNIT" 2>/dev/null || true

cat <<EOF

$NAME is uninstalled. If this still lists the plain
com.steampowered.PressureVessel.LaunchAlongsideSteam name, it goes away the
next time Steam restarts:

    busctl --user list | grep LaunchAlongsideSteam
EOF
