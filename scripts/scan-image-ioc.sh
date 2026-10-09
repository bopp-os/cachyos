#!/bin/bash
set -euo pipefail
IMAGE_REF=$1

echo "::group::Post-build Image IOC Scan for $IMAGE_REF"
echo "Scanning image filesystem for known IOCs..."

CONTAINER_ID=$(sudo podman create "$IMAGE_REF")
MNT_DIR=$(sudo podman mount "$CONTAINER_ID")
trap "sudo podman unmount $CONTAINER_ID >/dev/null 2>&1 || true; sudo podman rm $CONTAINER_ID >/dev/null 2>&1" EXIT

# Build file listing once in memory from the mount — completely avoids disk I/O
echo "Building file listing from mount..."
# sed strips the mount prefix so paths match the expected relative format
FILE_LIST=$(sudo find "$MNT_DIR" -type f 2>/dev/null | sed "s|^$MNT_DIR/||")

FILE_COUNT=$(echo "$FILE_LIST" | grep -c . || true)
if [[ "$FILE_COUNT" -eq 0 ]]; then
  echo "::error::Image mount at $MNT_DIR has no files; refusing to report a clean scan."
  exit 1
fi
echo "Scanning $FILE_COUNT files..."

FOUND=0
FINDINGS=()

# --- Wave 1 & 2: All path-based IOCs in a single grep pass ---
PATH_PATTERN="atomic-lockfile|js-digest|lockfile-js|nextfile-js|src/hooks/deps|node_modules/\.bun|_cacache/.*atomic-lockfile|bun/install/cache/.*js-digest|usr/bin/monero-wallet-gui"
result=$(echo "$FILE_LIST" | grep -E "$PATH_PATTERN" || true)
if [[ -n "$result" ]]; then
  FINDINGS+=("PATH IOC: $result")
  FOUND=1
fi

# --- eBPF rootkit pinned maps ---
BPF_result=$(echo "$FILE_LIST" | grep -F "sys/fs/bpf/hidden_" || true)
if [[ -n "$BPF_result" ]]; then
  FINDINGS+=("EBPF_ROOTKIT ARTIFACT: $BPF_result")
  FOUND=1
fi

# --- Payload size fingerprint (deps ELF is exactly 3,040,376 bytes) ---
SUSPICIOUS_FILES=$(sudo find "$MNT_DIR" -type f -size 3040376c 2>/dev/null | sed "s|^$MNT_DIR/||" || true)
if [[ -n "$SUSPICIOUS_FILES" ]]; then
  FINDINGS+=("SUSPICIOUS_SIZE(3040376 - known deps payload): $SUSPICIOUS_FILES")
  FOUND=1
fi

# --- Package .install & ALPM Scriptlet Heuristics ---
echo "Auditing pacman package .install scriptlets for heuristics..."
# The real database lives under /usr/lib/sysimage. /var/lib/pacman is an absolute symlink
# that resolves against the runner's filesystem, not the mounted image, so never use it.
PACMAN_DB="$MNT_DIR/usr/lib/sysimage/lib/pacman/local"
if ! sudo test -d "$PACMAN_DB" || sudo test -L "$PACMAN_DB"; then
  echo "::error::Pacman database not found at ${PACMAN_DB#$MNT_DIR}; cannot audit scriptlets."
  exit 1
fi
DB_ENTRIES=$(sudo find "$PACMAN_DB" -mindepth 1 -maxdepth 1 -type d | wc -l)
if [[ "$DB_ENTRIES" -eq 0 ]]; then
  echo "::error::Pacman database at ${PACMAN_DB#$MNT_DIR} is empty; cannot audit scriptlets."
  exit 1
fi
INSTALL_HOOKS=$(sudo find "$PACMAN_DB" -type f \( -name "install" -o -name "*.install" \))
echo "Found $(echo "$INSTALL_HOOKS" | grep -c . || true) scriptlets across $DB_ENTRIES installed packages."

if [[ -n "$INSTALL_HOOKS" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    clean_name=${file#$MNT_DIR/}

    # Read content stripping comment lines
    HOOK_CONTENT=$(sudo grep -vE '^\s*#' "$file" 2>/dev/null || true)

    # 1. Obfuscation & Dynamic Evaluation
    if echo "$HOOK_CONTENT" | grep -qE '(base64\s+(-d|--decode)|eval\s+(\$|`)|openssl\s+enc|xxd\s+-r|\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic-lockfile)'; then
      FINDINGS+=("OBFUSCATED_INSTALL_HOOK: obfuscation, hex escapes, or eval in $clean_name")
      FOUND=1
    fi

    # 2. Network Egress / Webhooks in Install Script
    if echo "$HOOK_CONTENT" | grep -qE '((curl|wget|fetch)\s+.*(\||>|\$\()|ncat\s|nc\s+-e|/dev/tcp/|discord\.com/api/webhooks|api\.telegram\.org)'; then
      FINDINGS+=("SUSPICIOUS_HOOK_NETWORK_CALL: outbound network or webhook in $clean_name")
      FOUND=1
    fi

    # 3. Sensitive Path / Credential Targeting
    if echo "$HOOK_CONTENT" | grep -qE '(/etc/shadow|\.ssh/id_|\.aws/credentials|\.config/(BraveSoftware|google-chrome|chromium)/.*Default)'; then
      FINDINGS+=("SUSPICIOUS_HOOK_SENSITIVE_ACCESS: target sensitive path in $clean_name")
      FOUND=1
    fi

    # 4. Package Manager Invocation
    if echo "$HOOK_CONTENT" | grep -qE '(bun|npm|pnpm|yarn)\s+(install|add)\s+.*(lockfile|digest|nextfile)'; then
      FINDINGS+=("MALICIOUS_INSTALL_HOOK: package manager running suspicious package in $clean_name")
      FOUND=1
    fi
  done <<< "$INSTALL_HOOKS"
fi

# --- Leftover / Drop Directory Check ---
echo "Auditing temp drop directories (/tmp, /var/tmp, /dev/shm)..."
SUSPICIOUS_DROPS=$(sudo find "$MNT_DIR/tmp" "$MNT_DIR/var/tmp" "$MNT_DIR/dev/shm" -type f 2>/dev/null | sed "s|^$MNT_DIR||" || true)
if [[ -n "$SUSPICIOUS_DROPS" ]]; then
  FINDINGS+=("UNEXPECTED_TEMP_DROPS found in built image: $SUSPICIOUS_DROPS")
  FOUND=1
fi

# --- Systemd Service Persistence Audit ---
echo "Auditing systemd service units for suspicious execution..."
SVC_UNITS=$(sudo find "$MNT_DIR/etc/systemd/system" "$MNT_DIR/usr/lib/systemd/system" -type f -name "*.service" 2>/dev/null || true)
if [[ -n "$SVC_UNITS" ]]; then
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue
    clean_svc=${svc#$MNT_DIR/}

    # Exclude known legitimate system services
    if [[ "$clean_svc" == *"xfs_scrub"* ]] || [[ "$clean_svc" == *"brew-setup.service"* ]]; then
      continue
    fi

    if sudo grep -qE 'ExecStart\s*=\s*(/tmp/|/var/tmp/|/dev/shm/|curl\s|wget\s|sh\s+-c\s+.*https?://)' "$svc" 2>/dev/null; then
      FINDINGS+=("SUSPICIOUS_SYSTEMD_SERVICE: suspicious ExecStart path or network call in $clean_svc")
      FOUND=1
    fi
  done <<< "$SVC_UNITS"
fi

# --- Report ---
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