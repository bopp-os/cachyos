#!/bin/bash
set -euo pipefail
IMAGE_REF=$1

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=scripts/scan-patterns.sh
source "$SCRIPT_DIR/scan-patterns.sh"
SETUID_ALLOWLIST="$SCRIPT_DIR/../files/security/setuid-allowlist.txt"

echo "::group::Post-build Image IOC Scan for $IMAGE_REF"
echo "Scanning image filesystem for known IOCs..."

CONTAINER_ID=$(sudo podman create "$IMAGE_REF")
MNT_DIR=$(sudo podman mount "$CONTAINER_ID")
# shellcheck disable=SC2064 # expand the container ID now; it is fixed for this run
trap "sudo podman unmount $CONTAINER_ID >/dev/null 2>&1 || true; sudo podman rm $CONTAINER_ID >/dev/null 2>&1" EXIT

# One walk of the image collects mode, size and path for every regular file; every check
# below works from this listing instead of walking the tree again
echo "Building file listing from mount..."
LISTING=$(sudo find "$MNT_DIR" -type f -printf '%m %s %P\n' 2>/dev/null || true)
FILE_LIST=$(cut -d' ' -f3- <<< "$LISTING")

FILE_COUNT=$(grep -c . <<< "$FILE_LIST" || true)
if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "::error::Image mount at $MNT_DIR has no files; refusing to report a clean scan."
  exit 1
fi
echo "Scanning $FILE_COUNT files..."

FOUND=0
FINDINGS=()
WARNINGS=()

# --- Known IOC paths (campaign artifacts, eBPF rootkit maps, ld.so.preload) ---
result=$(grep -E "$PAT_IOC_PATHS" <<< "$FILE_LIST" || true)
if [[ -n "$result" ]]; then
  FINDINGS+=("IOC_PATH: $(tr '\n' ' ' <<< "$result")")
  FOUND=1
fi

# --- Payload size fingerprint (deps ELF is exactly 3,040,376 bytes) ---
result=$(awk '$2 == 3040376 {print $3}' <<< "$LISTING")
if [[ -n "$result" ]]; then
  FINDINGS+=("SUSPICIOUS_SIZE(3040376 - known deps payload): $(tr '\n' ' ' <<< "$result")")
  FOUND=1
fi

# --- Leftover / drop directories ---
result=$(grep -E '^(tmp|var/tmp|dev/shm)/' <<< "$FILE_LIST" || true)
if [[ -n "$result" ]]; then
  FINDINGS+=("UNEXPECTED_TEMP_DROPS: $(tr '\n' ' ' <<< "$result")")
  FOUND=1
fi

# --- Setuid/setgid files not on the allowlist ---
echo "Auditing setuid/setgid files..."
mapfile -t ALLOWED < <(grep -vE '^\s*(#|$)' "$SETUID_ALLOWLIST")
while read -r mode path; do
  [[ -z "$path" ]] && continue
  allowed=0
  for pattern in "${ALLOWED[@]}"; do
    # shellcheck disable=SC2053 # allowlist entries are glob patterns
    if [[ "$path" == $pattern ]]; then
      allowed=1
      break
    fi
  done
  if [[ $allowed -eq 0 ]]; then
    WARNINGS+=("Unexpected setuid/setgid file (mode $mode): /$path")
  fi
done < <(awk 'length($1) == 4 && substr($1, 1, 1) ~ /[2-7]/ {print $1, $3}' <<< "$LISTING")

# --- Package scriptlets, ALPM scripts and login scripts ---
echo "Auditing package scriptlets, ALPM scripts and profile.d..."
# The real database lives under /usr/lib/sysimage. /var/lib/pacman is an absolute symlink
# that resolves against the runner's filesystem, not the mounted image, so never use it.
DB_ENTRIES=$(grep -cE '^usr/lib/sysimage/lib/pacman/local/[^/]+/desc$' <<< "$FILE_LIST" || true)
if [[ "$DB_ENTRIES" -eq 0 ]]; then
  echo "::error::Pacman database not found under /usr/lib/sysimage/lib/pacman/local; cannot audit scriptlets."
  exit 1
fi
mapfile -t SCRIPTS < <(grep -E '^(usr/lib/sysimage/lib/pacman/local/[^/]+/install|usr/share/libalpm/scripts/[^/]+|etc/profile\.d/[^/]+\.sh)$' <<< "$FILE_LIST" || true)
for script in "${SCRIPTS[@]}"; do
  check_script "/$script" "$(sudo cat "$MNT_DIR/$script")"
done
echo "Checked ${#SCRIPTS[@]} scripts across $DB_ENTRIES installed packages."

# --- Exec*= lines in systemd units, ALPM hooks and autostart entries ---
echo "Auditing systemd units, ALPM hooks and autostart entries..."
mapfile -t EXEC_FILES < <(grep -E '^((usr/lib|etc)/systemd/(system|user)/[^/]+\.(service|socket)|(usr/share/libalpm/hooks|etc/pacman\.d/hooks)/[^/]+\.hook|etc/xdg/autostart/[^/]+\.desktop)$' <<< "$FILE_LIST" || true)
if [ ${#EXEC_FILES[@]} -gt 0 ]; then
  # Known legitimate units that fetch from the network at runtime
  EXEC_HITS=$(printf '%s\0' "${EXEC_FILES[@]/#/$MNT_DIR/}" | sudo xargs -0 grep -HE "$PAT_EXEC_LINE" 2>/dev/null |
    sed "s|^$MNT_DIR/||" | grep -vE '^usr/lib/systemd/system/(brew-setup\.service|xfs_scrub[^:]*):' || true)
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    line=${hit#*:}
    FINDINGS+=("SUSPICIOUS_EXEC in /${hit%%:*}: ${line#"${line%%[![:space:]]*}"}")
    FOUND=1
  done <<< "$EXEC_HITS"
fi
echo "Checked ${#EXEC_FILES[@]} units, hooks and autostart entries."

# --- Report ---
for w in "${WARNINGS[@]}"; do
  echo "::warning::$w"
done

if [[ $FOUND -eq 1 ]]; then
  echo "::error::🚨 COMPROMISED IMAGE DETECTED! 🚨"
  echo "The following suspicious indicators were found in $IMAGE_REF:"
  for f in "${FINDINGS[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "✅ No known IOCs found in the image."
echo "::endgroup::"
