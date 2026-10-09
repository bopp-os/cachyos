#!/bin/bash
set -eo pipefail

echo "::group::Configuring Pacman Repositories & Keyrings"

# Ensure DisableSandboxNetwork is enabled early for container builds
grep -q "DisableSandboxNetwork" /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandboxNetwork' /etc/pacman.conf

# 1. Re-initialize and trust keys
pacman -Sy --noconfirm archlinux-keyring cachyos-keyring gnupg curl
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

curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF3B607488DB35A47" | pacman-key --add - || echo "Key refresh failed, using committed copy"
curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB" | pacman-key --add - || echo "Key refresh failed, using committed copy"
curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3056513887B78AEB" | pacman-key --add - || echo "Key refresh failed, using committed copy"
pacman-key --lsign-key F3B607488DB35A47 || true
pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB || true
pacman-key --lsign-key 3056513887B78AEB || true
pacman-key --lsign-key 3806768589376830FEA123D6CF30985CE903D47C || true

# Add boppos repository GPG key and locally sign it
KEY_FILE=""
if [ -n "$KEYS_DIR" ] && [ -f "$KEYS_DIR/boppos.asc" ]; then
  KEY_FILE="$KEYS_DIR/boppos.asc"
elif [ -f "/tmp/keys/boppos.asc" ]; then
  KEY_FILE="/tmp/keys/boppos.asc"
elif [ -f "/tmp/files/keys/boppos.asc" ]; then
  KEY_FILE="/tmp/files/keys/boppos.asc"
elif curl -fsSL --max-time 10 https://repo.ripps.me/boppos.gpg -o /tmp/boppos.gpg 2>/dev/null; then
  KEY_FILE="/tmp/boppos.gpg"
fi

# [bopp-os] requires signatures, so a missing or untrusted key must fail the build here
# rather than as a confusing signature error later
if [ -z "$KEY_FILE" ]; then
  echo "::error::bopp-os signing key not found; cannot verify [bopp-os] packages."
  exit 1
fi
pacman-key --add "$KEY_FILE"
BOPPOS_FINGERPRINT=$(gpg --with-colons --show-keys "$KEY_FILE" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
pacman-key --lsign-key "${BOPPOS_FINGERPRINT:-3806768589376830FEA123D6CF30985CE903D47C}"
rm -f /tmp/boppos.gpg

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
  # Packages and the database are signed with files/keys/boppos.asc; [bopp-os] sits above
  # [extra], so an unsigned package here could replace an official one
  printf "\n[bopp-os]\nSigLevel = Required DatabaseRequired\nServer = https://repo.ripps.me\n\n" > /tmp/bopp-os.conf
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
pacman -Sy --noconfirm --needed cachyos-hooks gpgme
# Download a package and its detached signature from the first mirror that serves a pair
# that verifies against the pacman keyring (chaotic keys come from files/keys above).
# The .sig stays next to the package so pacman -U checks it again on install.
download_pkg() {
  local target="$1"
  shift
  local urls=("$@")
  rm -f "$target" "$target.sig"
  for url in "${urls[@]}"; do
    echo "Attempting to download $(basename "$target") from $url..."
    if curl -f -s -S -L --retry 3 --retry-delay 2 --retry-connrefused --max-time 30 "$url" -o "$target" &&
      curl -f -s -S -L --retry 3 --retry-delay 2 --retry-connrefused --max-time 30 "$url.sig" -o "$target.sig"; then
      if pacman-key --verify "$target.sig" "$target" >/dev/null 2>&1; then
        echo "Successfully downloaded and verified signature of $(basename "$target")"
        return 0
      fi
      echo "::warning::Signature check failed for $(basename "$target") from $url, trying next mirror..."
    fi
    rm -f "$target" "$target.sig"
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

if download_pkg /tmp/chaotic-keyring.pkg.tar.zst "${CHAOTIC_KEYRING_URLS[@]}" && \
   download_pkg /tmp/chaotic-mirrorlist.pkg.tar.zst "${CHAOTIC_MIRRORLIST_URLS[@]}"; then
  pacman -U --overwrite '*' --noconfirm /tmp/chaotic-keyring.pkg.tar.zst /tmp/chaotic-mirrorlist.pkg.tar.zst
  rm -f /tmp/chaotic-keyring.pkg.tar.zst* /tmp/chaotic-mirrorlist.pkg.tar.zst*
  pacman-key --populate chaotic || true
else
  echo "Warning: Could not download chaotic-aur packages; writing fallback mirrorlist..."
  mkdir -p /etc/pacman.d
  cat << 'EOF' > /etc/pacman.d/chaotic-mirrorlist
Server = https://cdn-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://geo-mirror.chaotic.cx/chaotic-aur/$arch
Server = https://builds.garudalinux.org/repos/chaotic-aur/$arch
Server = https://mirror.albony.in/chaotic-aur/$arch
EOF
fi

if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
  # Packages are signed; chaotic-aur does not publish a database signature
  echo -e '\n[chaotic-aur]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
fi

{ pkill -9 gpg-agent || true; pkill -9 dirmngr || true; pkill -9 keyboxd || true; pkill -9 scdaemon || true; }
echo "::endgroup::"
