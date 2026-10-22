#!/bin/bash
# Checks whether the committed Chaotic-AUR keys (files/keys/chaotic-*.asc) are still current. Read-only: it never
# changes the keys, which are updated by hand after review.
#
# Usage: check-chaotic-keys.sh [--keyserver] [keys-dir]
#   Always:       verifies the signature of Chaotic's current chaotic-keyring package against the committed keys.
#   --keyserver:  also compares each committed key with the keyserver copy of the same fingerprint (new, expired or
#                 revoked subkeys, changed expiry dates).
# Exit: 0 keys current (or the check couldn't run), 2 keys out of date (details on stdout), 1 error.
set -eo pipefail

KEYSERVER=0
KEYS_DIR="files/keys"
for arg in "$@"; do
  case "$arg" in
    --keyserver) KEYSERVER=1 ;;
    *) KEYS_DIR="$arg" ;;
  esac
done

shopt -s nullglob
KEYS=("$KEYS_DIR"/chaotic-*.asc)
if [ ${#KEYS[@]} -eq 0 ]; then
  echo "::error::No Chaotic-AUR keys found in $KEYS_DIR"
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "${KEYS[@]}" 2>/dev/null

STALE=()

# Same mirrors as setup_pacman_repos.sh
CHAOTIC_KEYRING_URLS=(
  'https://cdn-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://geo-mirror.chaotic.cx/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://builds.garudalinux.org/repos/chaotic-aur/chaotic-keyring.pkg.tar.zst'
  'https://mirror.albony.in/chaotic-aur/chaotic-keyring.pkg.tar.zst'
)
PKG="$WORK/chaotic-keyring.pkg.tar.zst"
fetch() {
  curl -f -s -S -L --retry 3 --retry-delay 2 --retry-connrefused --max-time 30 "$1" -o "$2" && [ -s "$2" ]
}
downloaded=0
for url in "${CHAOTIC_KEYRING_URLS[@]}"; do
  if fetch "$url" "$PKG" && fetch "$url.sig" "$PKG.sig"; then downloaded=1; break; fi
done

if [ "$downloaded" = 0 ]; then
  echo "::warning::Couldn't download chaotic-keyring from any mirror; skipping the signature check"
else
  status=$(gpg --batch --status-fd 1 --verify "$PKG.sig" "$PKG" 2>/dev/null || true)
  if grep -q '^\[GNUPG:\] BADSIG' <<<"$status"; then
    echo "::error::chaotic-keyring from $url has a bad signature (corrupt or tampered download)"
    exit 1
  fi
  # One line per key: "<key id> <gpg statuses>"
  stale=$(awk '$2 ~ /^(NO_PUBKEY|EXPKEYSIG|REVKEYSIG|KEYEXPIRED|KEYREVOKED|ERRSIG)$/ && index(seen[$3], $2) == 0 {
      seen[$3] = seen[$3] (seen[$3] ? "," : "") $2 }
    END { for (k in seen) print k, seen[k] }' <<<"$status")
  if [ -n "$stale" ]; then
    while read -r key what; do
      STALE+=("chaotic-keyring is signed by key $key, which the committed keys don't cover ($what)")
    done <<<"$stale"
  elif grep -q '^\[GNUPG:\] VALIDSIG' <<<"$status"; then
    echo "chaotic-keyring signature verifies against the committed keys"
  else
    echo "::error::Unexpected gpg result verifying chaotic-keyring:"
    echo "$status"
    exit 1
  fi
fi

# Sub-key ids, validity and expiry of one key file, one line per key: "<type> <keyid> <validity> <expiry date>"
describe() {
  local type keyid validity expires
  gpg --with-colons --show-keys "$1" 2>/dev/null \
    | awk -F: '/^(pub|sub)/ {print $1, $5, ($2 == "r" ? "revoked" : $2 == "e" ? "expired" : "valid"), ($7 ? $7 : "never")}' \
    | while read -r type keyid validity expires; do
        [ "$expires" = never ] || expires=$(date -u -d "@$expires" +%F)
        echo "$type $keyid $validity expires:$expires"
      done
}

if [ "$KEYSERVER" = 1 ]; then
  for key in "${KEYS[@]}"; do
    fpr=$(gpg --with-colons --show-keys "$key" 2>/dev/null | awk -F: '/^pub/ {p=1; next} /^fpr/ && p {print $10; exit}')
    remote="$WORK/$(basename "$key")"
    if ! curl -fsS --max-time 30 -o "$remote" "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x$fpr"; then
      echo "::warning::Couldn't fetch $fpr from the keyserver; skipping $(basename "$key")"
      continue
    fi
    got=$(gpg --with-colons --show-keys "$remote" 2>/dev/null | awk -F: '/^pub/ {p=1; next} /^fpr/ && p {print $10; p=0}')
    if [ "$got" != "$fpr" ]; then
      echo "::error::Keyserver returned ${got:-no key} for $fpr ($(basename "$key"))"
      exit 1
    fi
    changes=$(diff <(describe "$key") <(describe "$remote") | sed -n 's/^< /committed: /p; s/^> /keyserver: /p' || true)
    if [ -n "$changes" ]; then
      STALE+=("$(basename "$key") ($fpr) differs from the keyserver copy:"$'\n'"$changes")
    else
      echo "$(basename "$key") matches the keyserver copy"
    fi
  done
fi

if [ ${#STALE[@]} -gt 0 ]; then
  echo "Chaotic-AUR keys are out of date:"
  printf -- '- %s\n' "${STALE[@]}"
  exit 2
fi
echo "Chaotic-AUR keys are current"
