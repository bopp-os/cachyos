#!/usr/bin/env bash
# Install steamvr-busname-fix as a systemd user service. No root needed.
# Re-running it upgrades an existing install in place.
set -euo pipefail

readonly NAME=steamvr-busname-fix
readonly UNIT=$NAME.service
src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir=$HOME/.local/bin
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

die() {
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

((EUID != 0)) || die "run this as your normal user, not as root or with sudo (it installs a per-user service)"
[[ -f $src/$NAME && -f $src/$UNIT ]] || die "$NAME and $UNIT must be next to install.sh (in $src)"
command -v busctl >/dev/null || die "busctl not found (it ships with systemd)"
systemctl --user show-environment >/dev/null 2>&1 ||
    die "can't reach your systemd user manager (systemctl --user); run this from your desktop session"

install -Dm755 "$src/$NAME" "$bin_dir/$NAME"
install -Dm644 "$src/$UNIT" "$unit_dir/$UNIT"
echo "installed $bin_dir/$NAME"
echo "installed $unit_dir/$UNIT"

systemctl --user daemon-reload
systemctl --user enable "$UNIT"
# Starts it, or restarts it so an upgrade takes effect.
systemctl --user restart "$UNIT"

if [[ -d $HOME/.var/app/com.valvesoftware.Steam ]]; then
    echo
    echo "note: Flatpak Steam data found. This workaround is only tested with native Steam."
fi

cat <<EOF

$NAME is running and will start with every login.
With Steam running, check that both names are on the bus:

    busctl --user list | grep LaunchAlongsideSteam

and that the service registered the plain one:

    journalctl --user -u $NAME
EOF
