#!/bin/bash
# ClamAV scan of everything the build pulls in from outside the repo, run right after Containerfile.prefetch:
#   1. new package archives in the pre-fetched pacman cache, plus what prefetch saved for the offline builds: the
#      Chaotic keyring/mirrorlist packages (.bootstrap/) and the kernel module source tarballs (.src/)
#   2. the Homebrew files copied from the brew image (COPY --from=brew in Containerfile.base)
#   3. the upstream base image rootfs (files it ships with that never pass through the package cache)
#   4. the container images of the tools the workflows run (chunkah, syft, grype), whole; the workflows then run them
#      with --pull=never, so they use exactly the copy scanned here
#
# Uses the clamav/clamav container, like the pkgbuilds repo, running one clamd for the whole step: the signature
# database loads once, and --multiscan spreads the files over every core (the scan runs before the build, so the cores
# are otherwise idle). Anything already scanned clean (package by SHA-256,
# image by ID) is recorded and skipped on later runs. The record sits one level up from <cache_dir>, so it is shared by
# the per-arch caches (<root>/v3, <root>/v4, ...): any-arch packages, packages from the shared repos and the brew image
# are scanned once for all arches. The build workflows share one concurrency group, so only one run writes it at a time.
#
# Usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image> [tool_image...]
set -euo pipefail

CACHE_DIR=$(readlink -f "${1:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image> [tool_image...]}")
BASE_IMAGE=${2:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image> [tool_image...]}
BREW_IMAGE=${3:?usage: clamscan-prefetch.sh <cache_dir> <base_image> <brew_image> [tool_image...]}
TOOL_IMAGES=("${@:4}")
CLAMAV_IMAGE="docker.io/clamav/clamav:stable"
CACHE_ROOT=$(dirname "$CACHE_DIR")
CACHE_FILE="$CACHE_ROOT/.clamav_scan_cache"
# Per-arch record from before the record was shared; merged in once, then removed.
LEGACY_CACHE_FILE="$CACHE_DIR/.clamav_scan_cache"
# Unpacked packages are scanned in batches of about this much compressed data, so a cold cache does not need the
# whole package set unpacked on disk at once. The record is saved after each batch, so a cancelled or timed-out run
# keeps what it already scanned.
BATCH_BYTES=$((2 * 1024 * 1024 * 1024))
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

WORK_DIR=$(mktemp -d /var/tmp/clamscan-prefetch.XXXXXX)
CLAMD_CTR="clamscan-prefetch-$$"
MOUNTED_IMAGES=()
cleanup() {
  sudo podman rm -f -t 0 "$CLAMD_CTR" >/dev/null 2>&1 || true
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

# Scans the given paths inside the clamd container (WORK_DIR is /scan/work there) with clamdscan --multiscan; clamdscan
# options such as --file-list=/scan/work/<list> can be passed too.
# Returns 0 when clean; findings and scan errors are added to FINDINGS. FLAGGED_PATHS lists the files with findings,
# and SCAN_RC is clamdscan's exit code (1: findings only, 2: scan errors).
clamd_scan() {
  local out rc
  FLAGGED_PATHS=()
  set +e
  out=$(sudo podman exec "$CLAMD_CTR" clamdscan --config-file=/scan/work/clamd.conf \
    --multiscan --no-summary --infected "$@" 2>&1)
  rc=$?
  SCAN_RC=$rc
  set -e
  case $rc in
    0) return 0 ;;
    1)
      while IFS= read -r line; do
        FINDINGS+=("${line#/scan/}")
        FLAGGED_PATHS+=("${line%%: *}")
      done < <(echo "$out" | grep 'FOUND$')
      ;;
    *)
      echo "$out"
      FINDINGS+=("clamdscan exited with $rc while scanning: $(echo "$out" | grep -m5 -i 'error' | tr '\n' ' ')")
      ;;
  esac
  return 1
}

# Sets IMAGE_ID and IMAGE_MNT (the read-only rootfs). IMAGE_MNT stays empty if this image ID is already clean,
# unless a second argument names a file that must exist (it is then mounted anyway, so that file can be created).
# Pulls only when missing, the same policy podman build uses, so the scanned image is the one the build gets.
mount_unscanned_image() {
  local ref=$1 needed=${2:-}
  IMAGE_MNT=""
  IMAGE_CLEAN=""
  sudo podman image exists "$ref" || sudo podman pull -q "$ref" >/dev/null
  IMAGE_ID=$(sudo podman image inspect --format '{{.Id}}' "$ref")
  if [[ -n "${SCANNED["$IMAGE_ID image:$ref"]:-}" ]]; then
    KEEP["$IMAGE_ID image:$ref"]=1
    IMAGE_CLEAN=1
    echo "  ✓ $ref already scanned clean, skipping."
    [[ -z "$needed" || -f "$needed" ]] && return 0
  fi
  MOUNTED_IMAGES+=("$ref")
  IMAGE_MNT=$(sudo podman image mount "$ref")
}

# Writes the record. Mid-run it holds every entry known clean so far; with "final", only the entries kept by the
# pruning at the end.
save_record() {
  local tmp="$WORK_DIR/clamav_scan_cache"
  if [ "${1:-}" = "final" ]; then
    printf '%s\n' "${!KEEP[@]}" | sort -u -k2 > "$tmp"
  else
    printf '%s\n' "${!SCANNED[@]}" "${!KEEP[@]}" | sort -u -k2 > "$tmp"
  fi
  # The cache root is created by root, and the per-arch folders are not world-writable everywhere.
  sudo install -m 0644 "$tmp" "$CACHE_FILE"
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

# Images are mounted before clamd starts, because mounts made later do not show up inside its container.
TOOL_MNTS=()
TOOL_IDS=()
for ref in "${TOOL_IMAGES[@]}"; do
  mount_unscanned_image "$ref"
  TOOL_MNTS+=("$IMAGE_MNT")
  TOOL_IDS+=("$IMAGE_ID")
  # The workflows' image pruning skips these repositories, so drop the versions a pin bump left behind here
  sudo podman images --filter "reference=${ref%:*}" --format '{{.ID}}' | sort -u | grep -vx "${IMAGE_ID:0:12}" \
    | xargs -r sudo podman rmi >/dev/null 2>&1 || true
done
mount_unscanned_image "$BREW_IMAGE"
BREW_MNT=$IMAGE_MNT
BREW_ID=$IMAGE_ID
# The upstream base image is rebuilt often (daily for CachyOS), but most of its files stay the same. The SHA-256 of
# every file in the last clean rootfs is recorded per image ref, and a new image only has its new or changed files
# scanned.
BASE_FILES_RECORD="$CACHE_ROOT/.clamav_files.$(printf '%s' "$BASE_IMAGE" | tr -c 'A-Za-z0-9._-' '_')"
mount_unscanned_image "$BASE_IMAGE" "$BASE_FILES_RECORD"
BASE_MNT=$IMAGE_MNT
BASE_ID=$IMAGE_ID
BASE_CLEAN=$IMAGE_CLEAN

# Limits match the pkgbuilds repo's clamscan flags: oversized files count as findings, so nothing slips through
# unscanned. clamd runs as root in the container so it can read every file of the mounted rootfs.
cat > "$WORK_DIR/clamd.conf" <<EOF
Foreground yes
LocalSocket /tmp/clamd.sock
DatabaseDirectory /var/lib/clamav
MaxThreads $(nproc)
MaxDirectoryRecursion 64
ScanArchive yes
MaxFileSize 2000M
MaxScanSize 4000M
AlertExceedsMax yes
# Per-file time limit (default 2 min) and files per archive (default 10000), raised for large archives such as
# Firefox's omni.ja (now skipped, see clamav-exclude.conf); a file that still hits either counts as a finding
# (Heuristics.Limits.Exceeded.*).
MaxScanTime 900000
MaxFiles 100000
ConcurrentDatabaseReload no
EOF
# Paths skipped by policy: files/security/clamav-exclude.conf, one regex per line (comments and blank lines ignored)
EXCLUDE_CONF="$(dirname "$0")/../files/security/clamav-exclude.conf"
EXCLUDE_REGEXES=()
if [ -f "$EXCLUDE_CONF" ]; then
  mapfile -t EXCLUDE_REGEXES < <(grep -vE '^[[:space:]]*(#|$)' "$EXCLUDE_CONF")
fi
for re in "${EXCLUDE_REGEXES[@]}"; do
  echo "ExcludePath $re" >> "$WORK_DIR/clamd.conf"
done

# Lists the files under a host folder (seen by clamd at the given container path) that the exclude rules skip, so every
# skip shows up in the log and job summary
log_excluded() {
  local container_path=$1 host_path=$2 f
  [ ${#EXCLUDE_REGEXES[@]} -gt 0 ] || return 0
  while IFS= read -r f; do
    echo "  ⏭️  Not scanned (clamav-exclude.conf): ${f#/scan/}"
    printf -- '- Not scanned (clamav-exclude.conf): `%s`\n' "${f#/scan/}" >> "$SUMMARY"
  done < <(find "$host_path" -type f | sed "s#^$host_path#$container_path#" \
    | grep -E -f <(printf '%s\n' "${EXCLUDE_REGEXES[@]}") || true)
}
CLAMD_MOUNTS=("-v" "$WORK_DIR:/scan/work:ro")
[ -n "$BREW_MNT" ] && CLAMD_MOUNTS+=("-v" "$BREW_MNT/system_files:/scan/brew:ro")
[ -n "$BASE_MNT" ] && CLAMD_MOUNTS+=("-v" "$BASE_MNT:/scan/base:ro")
for i in "${!TOOL_IMAGES[@]}"; do
  [ -n "${TOOL_MNTS[$i]}" ] && CLAMD_MOUNTS+=("-v" "${TOOL_MNTS[$i]}:/scan/tool$i:ro")
done
sudo podman run -d --name "$CLAMD_CTR" --pull never --network=none --security-opt label=disable "${CLAMD_MOUNTS[@]}" \
  --entrypoint clamd "$CLAMAV_IMAGE" --config-file=/scan/work/clamd.conf >/dev/null
echo "  Waiting for clamd to load the signature database..."
if ! sudo podman exec "$CLAMD_CTR" clamdscan --config-file=/scan/work/clamd.conf --ping=300:1 >/dev/null 2>&1; then
  sudo podman logs --tail 20 "$CLAMD_CTR" || true
  echo "::error::clamd did not start"
  exit 1
fi

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
  log_excluded /scan/work/pkgs "$PKG_DIR"
  if clamd_scan /scan/work/pkgs; then
    for entry in "${BATCH[@]}"; do
      KEEP["$entry"]=1
    done
    save_record
  elif [ "$SCAN_RC" -eq 1 ]; then
    # Only findings, no scan errors: every package without one was scanned clean, so the rest of the batch is kept.
    declare -A flagged=()
    for path in "${FLAGGED_PATHS[@]}"; do
      path=${path#/scan/work/pkgs/}
      flagged["${path%%/*}"]=1
    done
    for entry in "${BATCH[@]}"; do
      [[ -z "${flagged[${entry#* }]:-}" ]] && KEEP["$entry"]=1
    done
    save_record
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
done < <({ find "$CACHE_DIR" -maxdepth 1 -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) -print0
  find "$CACHE_DIR/.bootstrap" "$CACHE_DIR/.src" -maxdepth 1 -type f \
    \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" -o -name "*.tar" \) -print0 2>/dev/null || true; })
scan_batch
echo "  Packages: $NEW_PKGS scanned, $SKIPPED_PKGS already clean."
printf -- '- Packages: %s scanned, %s already clean\n' "$NEW_PKGS" "$SKIPPED_PKGS" >> "$SUMMARY"

# -----------------------------------------------------------
# 2. Homebrew files from the brew image
# -----------------------------------------------------------
if [ -n "$BREW_MNT" ]; then
  echo "  🔍 Scanning $BREW_IMAGE..."
  BREW_UNPACKED="$WORK_DIR/brew"
  mkdir -p "$BREW_UNPACKED"
  while IFS= read -r -d '' tarball; do
    out="$BREW_UNPACKED/$(basename "$tarball").unpacked"
    mkdir -p "$out"
    sudo $TAR_CMD -xf "$tarball" -C "$out"
  done < <(sudo find "$BREW_MNT/system_files" -type f -name "*.tar.*" -print0)
  if clamd_scan /scan/brew /scan/work/brew; then
    KEEP["$BREW_ID image:$BREW_IMAGE"]=1
  fi
  sudo rm -rf "$BREW_UNPACKED"
  printf -- '- Brew image `%s`: scanned\n' "$BREW_IMAGE" >> "$SUMMARY"
else
  printf -- '- Brew image `%s`: already clean\n' "$BREW_IMAGE" >> "$SUMMARY"
fi

# -----------------------------------------------------------
# Tool images (chunkah, syft, grype)
# -----------------------------------------------------------
for i in "${!TOOL_IMAGES[@]}"; do
  ref=${TOOL_IMAGES[$i]}
  if [ -n "${TOOL_MNTS[$i]}" ]; then
    echo "  🔍 Scanning $ref..."
    clamd_scan "/scan/tool$i" && KEEP["${TOOL_IDS[$i]} image:$ref"]=1
    printf -- '- Tool image `%s`: scanned\n' "$ref" >> "$SUMMARY"
  else
    printf -- '- Tool image `%s`: already clean\n' "$ref" >> "$SUMMARY"
  fi
done

# -----------------------------------------------------------
# 3. Upstream base image rootfs
# -----------------------------------------------------------
if [ -n "$BASE_MNT" ]; then
  BASE_HASHES="$WORK_DIR/base-hashes"
  # -z turns off sha256sum's escaping of file names with a backslash or newline (systemd units such as
  # system-systemd\x2dcryptsetup.slice), which would otherwise mangle both the checksum and the path.
  sudo find "$BASE_MNT" -xdev -type f -print0 | sudo xargs -0 -r sha256sum -z | tr '\0' '\n' > "$BASE_HASHES"
  SCAN_LIST="$WORK_DIR/base-scan-list"
  # sha256sum prints "<64 hex>  <path>"; paths are rewritten to where the rootfs is mounted in the container
  awk -v mnt="$BASE_MNT/" 'FILENAME == ARGV[1] { clean[$1] = 1; next }
    !($1 in clean) { print "/scan/base/" substr($0, 67 + length(mnt)) }' \
    <(cat "$BASE_FILES_RECORD" 2>/dev/null) "$BASE_HASHES" > "$SCAN_LIST"
  BASE_TOTAL=$(wc -l < "$BASE_HASHES")
  BASE_NEW=$(wc -l < "$SCAN_LIST")
  if [ -n "$BASE_CLEAN" ]; then
    echo "  Recording file checksums of $BASE_IMAGE for later incremental scans."
    BASE_NEW=0
  elif [ "$BASE_NEW" -eq 0 ]; then
    BASE_CLEAN=1
  else
    echo "  🔍 Scanning $BASE_IMAGE rootfs: $BASE_NEW of $BASE_TOTAL files are new or changed..."
    clamd_scan --file-list=/scan/work/base-scan-list && BASE_CLEAN=1
  fi
  if [ -n "$BASE_CLEAN" ]; then
    KEEP["$BASE_ID image:$BASE_IMAGE"]=1
    cut -c1-64 "$BASE_HASHES" | sort -u > "$WORK_DIR/base-files-record"
    sudo install -m 0644 "$WORK_DIR/base-files-record" "$BASE_FILES_RECORD"
  fi
  echo "  Base image: $BASE_NEW of $BASE_TOTAL files scanned."
  printf -- '- Base image `%s`: %s of %s files scanned\n' "$BASE_IMAGE" "$BASE_NEW" "$BASE_TOTAL" >> "$SUMMARY"
else
  printf -- '- Base image `%s`: already clean\n' "$BASE_IMAGE" >> "$SUMMARY"
fi

# Only clean entries that still exist are kept, so pruned packages and replaced images drop out. Entries from the
# other arches stay while their package file is still in that arch's cache, or for images this run did not use.
for entry in "${!SCANNED[@]}"; do
  [[ -n "${KEEP[$entry]:-}" ]] && continue
  name=${entry#* }
  if [[ "$name" == image:* ]]; then
    # Older IDs of the images this run used are dropped; images other arches or runs use are kept
    used=0
    for ref in "$BASE_IMAGE" "$BREW_IMAGE" "${TOOL_IMAGES[@]}"; do
      [[ "$name" == "image:$ref" ]] && used=1
    done
    [ "$used" = 0 ] && KEEP["$entry"]=1
    continue
  fi
  for other in "$CACHE_ROOT"/*/"$name" "$CACHE_ROOT"/*/.bootstrap/"$name" "$CACHE_ROOT"/*/.src/"$name"; do
    if [[ -f "$other" && "$(dirname "$other")" != "$CACHE_DIR" ]]; then
      KEEP["$entry"]=1
      break
    fi
  done
done
save_record final
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
