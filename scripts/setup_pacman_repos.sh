#!/bin/bash
set -eo pipefail

echo "::group::Configuring Pacman Repositories & Keyrings"

# 1. Re-initialize and trust keys
pacman -Sy --noconfirm archlinux-keyring cachyos-keyring gnupg curl
rm -rf /etc/pacman.d/gnupg
pacman-key --init
echo "no-tty" >> /etc/pacman.d/gnupg/gpg.conf
pacman-key --populate archlinux cachyos

if [ -d "/tmp/keys" ]; then
  for key in /tmp/keys/*.asc; do [ -f "$key" ] && pacman-key --add "$key" || true; done
fi

curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xF3B607488DB35A47" | pacman-key --add - || echo "Key refresh failed, using committed copy"
curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB" | pacman-key --add - || echo "Key refresh failed, using committed copy"
curl -s --max-time 10 "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x3056513887B78AEB" | pacman-key --add - || echo "Key refresh failed, using committed copy"
pacman-key --lsign-key F3B607488DB35A47 || true
pacman-key --lsign-key 5DE6BF3EBC86402E7A5C5D241FA48C960F9604CB || true
pacman-key --lsign-key 3056513887B78AEB || true

# Add boppos repository GPG key and locally sign it
KEY_FILE=""
if [ -f "/tmp/keys/boppos.asc" ]; then
  KEY_FILE="/tmp/keys/boppos.asc"
elif curl -fsSL --max-time 10 https://repo.ripps.me/boppos.gpg -o /tmp/boppos.gpg 2>/dev/null; then
  KEY_FILE="/tmp/boppos.gpg"
fi

if [ -n "$KEY_FILE" ]; then
  pacman-key --add "$KEY_FILE" || true
  BOPPOS_FINGERPRINT=$(gpg --with-colons --show-keys "$KEY_FILE" 2>/dev/null | grep '^pub' | cut -d: -f5 || echo "")
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
pacman -Sy --noconfirm --needed cachyos-hooks gpgme
(curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' -o /tmp/chaotic-keyring.pkg.tar.zst || \
 curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst' -o /tmp/chaotic-keyring.pkg.tar.zst || \
 curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://builds.garudalinux.org/repos/chaotic-aur/chaotic-keyring.pkg.tar.zst' -o /tmp/chaotic-keyring.pkg.tar.zst)
(curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' -o /tmp/chaotic-mirrorlist.pkg.tar.zst || \
 curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' -o /tmp/chaotic-mirrorlist.pkg.tar.zst || \
 curl -s -S -L --retry 5 --retry-connrefused --max-time 30 'https://builds.garudalinux.org/repos/chaotic-aur/chaotic-mirrorlist.pkg.tar.zst' -o /tmp/chaotic-mirrorlist.pkg.tar.zst)

pacman -U --overwrite '*' --noconfirm /tmp/chaotic-keyring.pkg.tar.zst /tmp/chaotic-mirrorlist.pkg.tar.zst
rm -f /tmp/chaotic-keyring.pkg.tar.zst /tmp/chaotic-mirrorlist.pkg.tar.zst
pacman-key --populate chaotic || true

if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf; then
  echo -e '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist' >> /etc/pacman.conf
fi

{ pkill -9 gpg-agent || true; pkill -9 dirmngr || true; pkill -9 keyboxd || true; pkill -9 scdaemon || true; }
echo "::endgroup::"
