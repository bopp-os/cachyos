#!/bin/bash
# ClamAV scan of everything the build pulls in from outside the repo, run right after Containerfile.prefetch:
#   1. new package archives in the pre-fetched pacman cache
#   2. the Homebrew files copied from the brew image (COPY --from=brew in Containerfile.base)
#   3. the upstream base image rootfs (files it ships with that never pass through the package cache)
#
# Uses the clamav/clamav container, like the pkgbuilds repo. Anything already scanned clean (package by SHA-256,
# image by ID) is recorded and skipped on later runs. The record sits one level up from <cache_dir>, so it is shared by
# the per-arch caches (<root>/v3, <root>/v4, ...): any-arch packages, packages from the shared repos and the brew image
# are scanned once for all arches. The build workflows share one concurrency group, so only one run writes it at a time.
#
# Usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image>
set -euo pipefail

CACHE_DIR=$(readlink -f "${1:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image>}")
BASE_IMAGE=${2:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image>}
BREW_IMAGE=${3:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image>}
CLAMAV_IMAGE="docker.io/clamav/clamav:stable"
CACHE_ROOT=$(dirname "$CACHE_DIR")
CACHE_FILE="$CACHE_ROOT/.clamav_scan_cache"
# Per-arch record from before the record was shared; merged in once, then removed.
LEGACY_CACHE_FILE="$CACHE_DIR/.clamav_scan_cache"
# Unpacked packages are scanned in batches of about this much compressed data, so a cold cache does not need the
# whole package set unpacked on disk at once. Each batch reloads the signature database (~20-40s).
BATCH_BYTES=$((2 * 1024 * 1024 * 1024))
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

WORK_DIR=$(mktemp -d /var/tmp/clamscan-prefetch.XXXXXX)
MOUNTED_IMAGES=()
cleanup() {
  for img in "${MOUNTED_IMAGES[@]}"; do
    sudo podman image unmount "$img" >/dev/null 2>&1 || true
  done
  # Unpacked trees can be root-owned (brew) or contain read-only directories (packages)
  sudo rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Both are sets of "<sha256-or-image-id> <package-file-or-image:ref>" entries.
declare -A SCANNED=()
for f in "$CACHE_FILE" "$LEGACY_CACHE_FILE"; do
  [ -f "$f" ] || continue
  while IFS=' ' read -r hash name; do
    [[ -n "$name" && -n "$hash" ]] && SCANNED["$hash $name"]=1
  done < "$f"
done
declare -A KEEP=()
FINDINGS=()

# Scans the given host paths (each mounted read-only under /scan/<label>) in one clamscan run.
# Flags match the pkgbuilds repo: oversized files count as findings, so nothing slips through unscanned.
# Returns 0 when clean; findings and scan errors are added to FINDINGS.
clamscan_paths() {
  local mounts=() label path out rc
  while [ $# -gt 0 ]; do
    label=$1 path=$2
    shift 2
    mounts+=("-v" "$path:/scan/$label:ro")
  done
  set +e
  out=$(sudo podman run --rm --pull never --network=none --security-opt label=disable "${mounts[@]}" \
    --entrypoint clamscan "$CLAMAV_IMAGE" \
    --no-summary --infected --recursive --scan-archive=yes \
    --max-filesize=2000M --max-scansize=4000M --alert-exceeds-max=yes /scan 2>&1)
  rc=$?
  set -e
  case $rc in
    0) return 0 ;;
    1)
      while IFS= read -r line; do
        FINDINGS+=("${line#/scan/}")
      done < <(echo "$out" | grep 'FOUND$')
      ;;
    *)
      echo "$out"
      FINDINGS+=("clamscan exited with $rc while scanning: $(echo "$out" | grep -m5 -i 'error' | tr '\n' ' ')")
      ;;
  esac
  return 1
}

# Sets IMAGE_ID and IMAGE_MNT (the read-only rootfs). IMAGE_MNT stays empty if this image ID is already clean.
# Pulls only when missing, the same policy podman build uses, so the scanned image is the one the build gets.
mount_unscanned_image() {
  local ref=$1
  IMAGE_MNT=""
  sudo podman image exists "$ref" || sudo podman pull -q "$ref" >/dev/null
  IMAGE_ID=$(sudo podman image inspect --format '{{.Id}}' "$ref")
  if [[ -n "${SCANNED["$IMAGE_ID image:$ref"]:-}" ]]; then
    KEEP["$IMAGE_ID image:$ref"]=1
    echo "  ✓ $ref already scanned clean, skipping."
    return 0
  fi
  MOUNTED_IMAGES+=("$ref")
  IMAGE_MNT=$(sudo podman image mount "$ref")
}

TAR_CMD="tar"
if command -v bsdtar >/dev/null 2>&1; then
  TAR_CMD="bsdtar"
fi

echo "::group::ClamAV scan of pre-fetched packages, brew and base image"
# The image ships with the current signature database, so pulling it is the database update.
OLD_CLAMAV_ID=$(sudo podman image inspect --format '{{.Id}}' "$CLAMAV_IMAGE" 2>/dev/null || true)
sudo podman pull -q "$CLAMAV_IMAGE" >/dev/null
NEW_CLAMAV_ID=$(sudo podman image inspect --format '{{.Id}}' "$CLAMAV_IMAGE")
if [[ -n "$OLD_CLAMAV_ID" && "$OLD_CLAMAV_ID" != "$NEW_CLAMAV_ID" ]]; then
  sudo podman rmi "$OLD_CLAMAV_ID" >/dev/null 2>&1 || true
fi
sudo podman run --rm --pull never --entrypoint clamscan "$CLAMAV_IMAGE" --version
printf '## ClamAV prefetch scan\n\n' >> "$SUMMARY"

# -----------------------------------------------------------
# 1. Package archives
# -----------------------------------------------------------
PKG_DIR="$WORK_DIR/pkgs"
BATCH=()
BATCH_SIZE=0
NEW_PKGS=0
SKIPPED_PKGS=0

scan_batch() {
  [ ${#BATCH[@]} -eq 0 ] && return 0
  echo "  🔍 Scanning batch of ${#BATCH[@]} unpacked packages..."
  if clamscan_paths pkgs "$PKG_DIR"; then
    for entry in "${BATCH[@]}"; do
      KEEP["$entry"]=1
    done
  fi
  sudo rm -rf "$PKG_DIR"
  BATCH=()
  BATCH_SIZE=0
}

while IFS= read -r -d '' pkg_file; do
  pkg_name=$(basename "$pkg_file")
  pkg_hash=$(sha256sum "$pkg_file" | awk '{print $1}')
  if [[ -n "${SCANNED["$pkg_hash $pkg_name"]:-}" ]]; then
    KEEP["$pkg_hash $pkg_name"]=1
    SKIPPED_PKGS=$((SKIPPED_PKGS + 1))
    continue
  fi
  NEW_PKGS=$((NEW_PKGS + 1))
  # ClamAV does not reliably look inside zstd archives, so it scans the unpacked files.
  mkdir -p "$PKG_DIR/$pkg_name"
  $TAR_CMD -xf "$pkg_file" -C "$PKG_DIR/$pkg_name"
  BATCH+=("$pkg_hash $pkg_name")
  BATCH_SIZE=$((BATCH_SIZE + $(stat -c %s "$pkg_file")))
  if [ "$BATCH_SIZE" -ge "$BATCH_BYTES" ]; then
    scan_batch
  fi
done < <(find "$CACHE_DIR" -maxdepth 1 -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) -print0)
scan_batch
echo "  Packages: $NEW_PKGS scanned, $SKIPPED_PKGS already clean."
printf -- '- Packages: %s scanned, %s already clean\n' "$NEW_PKGS" "$SKIPPED_PKGS" >> "$SUMMARY"

# -----------------------------------------------------------
# 2. Homebrew files from the brew image
# -----------------------------------------------------------
mount_unscanned_image "$BREW_IMAGE"
BREW_MNT=$IMAGE_MNT
if [ -n "$BREW_MNT" ]; then
  echo "  🔍 Scanning $BREW_IMAGE..."
  BREW_UNPACKED="$WORK_DIR/brew"
  mkdir -p "$BREW_UNPACKED"
  while IFS= read -r -d '' tarball; do
    out="$BREW_UNPACKED/$(basename "$tarball").unpacked"
    mkdir -p "$out"
    sudo $TAR_CMD -xf "$tarball" -C "$out"
  done < <(sudo find "$BREW_MNT/system_files" -type f -name "*.tar.*" -print0)
  if clamscan_paths brew "$BREW_MNT/system_files" brew-unpacked "$BREW_UNPACKED"; then
    KEEP["$IMAGE_ID image:$BREW_IMAGE"]=1
  fi
  sudo rm -rf "$BREW_UNPACKED"
  printf -- '- Brew image `%s`: scanned\n' "$BREW_IMAGE" >> "$SUMMARY"
else
  printf -- '- Brew image `%s`: already clean\n' "$BREW_IMAGE" >> "$SUMMARY"
fi

# -----------------------------------------------------------
# 3. Upstream base image rootfs
# -----------------------------------------------------------
mount_unscanned_image "$BASE_IMAGE"
BASE_MNT=$IMAGE_MNT
if [ -n "$BASE_MNT" ]; then
  echo "  🔍 Scanning $BASE_IMAGE rootfs..."
  if clamscan_paths base "$BASE_MNT"; then
    KEEP["$IMAGE_ID image:$BASE_IMAGE"]=1
  fi
  printf -- '- Base image `%s`: scanned\n' "$BASE_IMAGE" >> "$SUMMARY"
else
  printf -- '- Base image `%s`: already clean\n' "$BASE_IMAGE" >> "$SUMMARY"
fi

# Only clean entries that still exist are kept, so pruned packages and replaced images drop out. Entries from the
# other arches stay while their package file is still in that arch's cache, or for images this run did not use.
for entry in "${!SCANNED[@]}"; do
  [[ -n "${KEEP[$entry]:-}" ]] && continue
  name=${entry#* }
  if [[ "$name" == image:* ]]; then
    [[ "$name" != "image:$BASE_IMAGE" && "$name" != "image:$BREW_IMAGE" ]] && KEEP["$entry"]=1
    continue
  fi
  for other in "$CACHE_ROOT"/*/"$name"; do
    if [[ -f "$other" && "$(dirname "$other")" != "$CACHE_DIR" ]]; then
      KEEP["$entry"]=1
      break
    fi
  done
done
TMP_CACHE="$WORK_DIR/clamav_scan_cache"
printf '%s\n' "${!KEEP[@]}" | sort -k2 > "$TMP_CACHE"
# The cache root is created by root, and the per-arch folders are not world-writable everywhere.
sudo install -m 0644 "$TMP_CACHE" "$CACHE_FILE"
sudo rm -f "$LEGACY_CACHE_FILE"

echo "::endgroup::"

if [ ${#FINDINGS[@]} -gt 0 ]; then
  printf '\n**ClamAV findings:**\n\n' >> "$SUMMARY"
  for finding in "${FINDINGS[@]}"; do
    echo "::error::ClamAV: $finding"
    printf -- '- `%s`\n' "$finding" >> "$SUMMARY"
  done
  exit 1
fi
echo "✅ ClamAV scan clean."
