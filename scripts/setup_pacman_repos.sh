#!/bin/bash
set -eo pipefail

# --online:  sync and download as before (used by prefetch, which saves what it downloads next to the cached packages)
# --offline: use only what prefetch saved: the frozen package databases, the cached packages and the saved Chaotic
#            keyring/mirrorlist. Nothing is downloaded.
# Default: offline when prefetch left everything needed, online otherwise (local builds).
MODE="auto"
for arg in "$@"; do
  case "$arg" in
    --online) MODE="online" ;;
    --offline) MODE="offline" ;;
  esac
done
SYNC_DB_DIR="${BOPPOS_SYNC_DB_DIR:-/var/lib/pacman/sync}"
FROZEN_DB_DIR="${BOPPOS_FROZEN_DB_DIR:-/var/cache/pacman/pkg/.sync}"
BOOTSTRAP_DIR="${BOPPOS_BOOTSTRAP_DIR:-/var/cache/pacman/pkg/.bootstrap}"
if [ "$MODE" = "auto" ]; then
  if compgen -G "$FROZEN_DB_DIR/*.db" >/dev/null; then
    MODE="offline"
  else
    MODE="online"
  fi
fi

# Full fingerprints of the committed Chaotic-AUR keys (files/keys/chaotic-*.asc, kept current by
# refresh-chaotic-keys.yml, which only accepts these exact keys)
CHAOTIC_FPRS="882DCFE48E2051D48E2562ABF3B607488DB35A47 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB EF925EA60F33D0CB85C44AD13056513887B78AEB"

# Installs repository packages: with a sync when online, from the frozen databases and the package cache when offline.
repo_install() {
  if [ "$MODE" = "offline" ]; then
    mkdir -p "$SYNC_DB_DIR"
    rm -f "$SYNC_DB_DIR"/*.db
    cp -f "$FROZEN_DB_DIR"/*.db "$SYNC_DB_DIR"/
    pacman -S --noconfirm "$@"
  else
    pacman -Sy --noconfirm "$@"
  fi
}

echo "::group::Configuring Pacman Repositories & Keyrings ($MODE)"

# Ensure DisableSandboxNetwork is enabled early for container builds
grep -q "DisableSandboxNetwork" /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandboxNetwork' /etc/pacman.conf

# 1. Re-initialize and trust keys
repo_install archlinux-keyring cachyos-keyring gnupg curl
rm -rf /etc/pacman.d/gnupg
pacman-key --init
echo "no-tty" >> /etc/pacman.d/gnupg/gpg.conf
pacman-key --populate archlinux cachyos

KEYS_DIR=""
if [ -d "/tmp/keys" ]; then
  KEYS_DIR="/tmp/keys"
elif [ -d "/tmp/files/keys" ]; then
  KEYS_DIR="/tmp/files/keys"
fi

if [ -n "$KEYS_DIR" ]; then
  for key in "$KEYS_DIR"/*.asc; do [ -f "$key" ] && pacman-key --add "$key" || true; done
fi

# Only the committed keys are trusted (no keyserver fetch here, so prefetch and the builds trust the same keys), and
# they are signed by full fingerprint
for fpr in $CHAOTIC_FPRS; do
  pacman-key --lsign-key "$fpr" || true
done
pacman-key --lsign-key 3806768589376830FEA123D6CF30985CE903D47C || true

# Add boppos repository GPG key and locally sign it
KEY_FILE=""
if [ -n "$KEYS_DIR" ] && [ -f "$KEYS_DIR/boppos.asc" ]; then
  KEY_FILE="$KEYS_DIR/boppos.asc"
elif [ -f "/tmp/keys/boppos.asc" ]; then
  KEY_FILE="/tmp/keys/boppos.asc"
elif [ -f "/tmp/files/keys/boppos.asc" ]; then
  KEY_FILE="/tmp/files/keys/boppos.asc"
elif [ "$MODE" = "online" ] && curl -fsSL --max-time 10 https://repo.ripps.me/boppos.gpg -o /tmp/boppos.gpg 2>/dev/null; then
  KEY_FILE="/tmp/boppos.gpg"
fi

if [ -n "$KEY_FILE" ]; then
  pacman-key --add "$KEY_FILE" || true
  BOPPOS_FINGERPRINT=$(gpg --with-colons --show-keys "$KEY_FILE" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}' || echo "3806768589376830FEA123D6CF30985CE903D47C")
  if [ -n "$BOPPOS_FINGERPRINT" ]; then
    pacman-key --lsign-key "$BOPPOS_FINGERPRINT" || true
  fi
  rm -f /tmp/boppos.gpg
fi

rm -rf /tmp/keys
{ pkill -9 gpg-agent || true; pkill -9 dirmngr || true; pkill -9 keyboxd || true; pkill -9 scdaemon || true; }

# 2. Configure pacman.conf & [bopp-os] repo
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
sed -i '/^DownloadUser/d' /etc/pacman.conf
grep -q "DisableSandboxNetwork" /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandboxNetwork' /etc/pacman.conf

# Ensure multilib repository is enabled
if grep -q '^#\[multilib\]' /etc/pacman.conf; then
  sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
elif ! grep -q '^\[multilib\]' /etc/pacman.conf; then
  echo -e '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist' >> /etc/pacman.conf
fi

# Ensure pacman cache directory path is consistent and symlinked
mkdir -p /var/cache/pacman/pkg /usr/lib/sysimage/cache/pacman
ln -sf /var/cache/pacman/pkg /usr/lib/sysimage/cache/pacman/pkg

if ! grep -q '\[bopp-os\]' /etc/pacman.conf; then
  printf "\n[bopp-os]\nSigLevel = Optional TrustAll\nServer = https://repo.ripps.me\n\n" > /tmp/bopp-os.conf
  sed -i '/^\[extra\]/i # bopp-os repo\n' /etc/pacman.conf
  awk -v repo_file="/tmp/bopp-os.conf" '/^# bopp-os repo/ { system("cat " repo_file); next } { print }' /etc/pacman.conf > /etc/pacman.conf.tmp
  mv /etc/pacman.conf.tmp /etc/pacman.conf
  rm -f /tmp/bopp-os.conf
fi

# 3. Disable unwanted build hooks
mkdir -p /etc/pacman.d/hooks
ln -sf /dev/null /etc/pacman.d/hooks/90-mkinitcpio-install.hook || true
ln -sf /dev/null /etc/pacman.d/hooks/90-dracut-install.hook || true
ln -sf /dev/null /etc/pacman.d/hooks/systemd-hwdb.hook || true
ln -sf /dev/null /etc/pacman.d/hooks/udev-hwdb.hook || true
ln -sf /dev/null /etc/pacman.d/hooks/archlinux-keyring-wkd-sync.hook || true

# 4. Install cachyos-hooks and [chaotic-aur] keyring/mirrorlist
repo_install --needed cachyos-hooks gpgme
download_pkg() {
  local target="$1"
  shift
  local urls=("$@")
  rm -f "$target"
  for url in "${urls[@]}"; do
    echo "Attempting to download $(basename "$target") from $url..."
    if curl -f -s -S -L --retry 3 --retry-delay 2 --retry-connrefused --max-time 30 "$url" -o "$target"; then
      if file "$target" 2>/dev/null | grep -qiE "zstandard|archive|tar" || zstd -t "$target" >/dev/null 2>&1; then
        echo "Successfully downloaded and verified $(basename "$target")"
        return 0
      fi
      echo "File downloaded from $url is not a valid archive (likely HTML error), trying next mirror..."
      rm -f "$target"
    fi
  done
  return 1
}

CHAOTIC_KEYRING_URLS=(
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://builds.garudalinux.org/repos/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://mirror.albony.in/chaotic-aur/chaotic-keyring.pkg.tar.zst'
)

CHAOTIC_MIRRORLIST_URLS=(
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  'https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  'https://builds.garudalinux.org/repos/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
  'https://mirror.albony.in/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst'
)

download_sig() {
  local target="$1"
  shift
  rm -f "$target"
  for url in "$@"; do
    if curl -f -s -S -L --retry 3 --retry-delay 2 --retry-connrefused --max-time 30 "$url" -o "$target" && [ -s "$target" ]; then
      return 0
    fi
  done
  rm -f "$target"
  return 1
}

# pacman -U does not check the signature of a local file, so check it here: the package must carry a valid signature
# (<file>.sig) whose primary key is one of the committed Chaotic-AUR keys.
verify_chaotic() {
  local primary
  primary=$(gpg --homedir /etc/pacman.d/gnupg --status-fd 1 --verify "$1.sig" "$1" 2>/dev/null \
    | awk '$2 == "VALIDSIG" {print $NF}')
  if [ -z "$primary" ] || [[ " $CHAOTIC_FPRS " != *" $primary "* ]]; then
    echo "::error::$(basename "$1") is not signed by a trusted Chaotic-AUR key; refusing to install it"
    exit 1
  fi
}

install_chaotic() {
  verify_chaotic "$1/chaotic-keyring.pkg.tar.zst"
  verify_chaotic "$1/chaotic-mirrorlist.pkg.tar.zst"
  pacman -U --overwrite '*' --noconfirm "$1/chaotic-keyring.pkg.tar.zst" "$1/chaotic-mirrorlist.pkg.tar.zst"
  pacman-key --populate chaotic || true
}

CHAOTIC_FILES="chaotic-keyring.pkg.tar.zst chaotic-keyring.pkg.tar.zst.sig chaotic-mirrorlist.pkg.tar.zst chaotic-mirrorlist.pkg.tar.zst.sig"
CHAOTIC_OK=0
if [ "$MODE" = "offline" ]; then
  # The prefetch step downloaded, verified and scanned these; installing them needs no network.
  have_all=1
  for f in $CHAOTIC_FILES; do [ -f "$BOOTSTRAP_DIR/$f" ] || have_all=0; done
  if [ "$have_all" = "1" ]; then
    install_chaotic "$BOOTSTRAP_DIR"
    CHAOTIC_OK=1
  fi
else
  # Files from an earlier prefetch must not be used if this one cannot get them
  for f in $CHAOTIC_FILES; do rm -f "$BOOTSTRAP_DIR/$f"; done
  mkdir -p /tmp/chaotic
  if download_pkg /tmp/chaotic/chaotic-keyring.pkg.tar.zst "${CHAOTIC_KEYRING_URLS[@]}" && \
     download_sig /tmp/chaotic/chaotic-keyring.pkg.tar.zst.sig "${CHAOTIC_KEYRING_URLS[@]/%/.sig}" && \
     download_pkg /tmp/chaotic/chaotic-mirrorlist.pkg.tar.zst "${CHAOTIC_MIRRORLIST_URLS[@]}" && \
     download_sig /tmp/chaotic/chaotic-mirrorlist.pkg.tar.zst.sig "${CHAOTIC_MIRRORLIST_URLS[@]/%/.sig}"; then
    install_chaotic /tmp/chaotic
    # Keep copies next to the cached packages so the offline builds can install them; the next ClamAV scan checks them.
    mkdir -p "$BOOTSTRAP_DIR" && (cd /tmp/chaotic && cp -f $CHAOTIC_FILES "$BOOTSTRAP_DIR"/) \
      || echo "Warning: could not save the Chaotic packages for the offline builds"
    CHAOTIC_OK=1
  fi
  rm -rf /tmp/chaotic
fi

if [ "$CHAOTIC_OK" = "0" ]; then
  echo "Warning: Chaotic-AUR keyring/mirrorlist packages not available; writing fallback mirrorlist (the committed keys are used)..."
  mkdir -p /etc/pacman.d
  cat << 'EOF' > /etc/pacman.d/chaotic-mirrorlist
Server = https://cdn-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://geo-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://builds.garudalinux.org/repos/chaotic-aur/$arch
Server = https://mirror.albony.in/chaotic-aur/$arch
EOF
fi

if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
  echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
fi

{ pkill -9 gpg-agent || true; pkill -9 dirmngr || true; pkill -9 keyboxd || true; pkill -9 scdaemon || true; }
echo "::endgroup::"
