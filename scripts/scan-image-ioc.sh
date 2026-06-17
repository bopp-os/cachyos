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

# --- Obfuscated .install hooks (Wave 2) ---
if echo "$FILE_LIST" | grep -q '\.install$'; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    clean_name=${file#$MNT_DIR/}
    
    if sudo grep -qE '\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic-lockfile' "$file" 2>/dev/null; then
      FINDINGS+=("OBFUSCATED_INSTALL_HOOK: hex escapes or known package names in $clean_name")
      FOUND=1
    fi
    if sudo grep -qE '(bun|npm|pnpm|yarn)\s+(install|add)\s+.*(lockfile|digest|nextfile)' "$file" 2>/dev/null; then
      FINDINGS+=("MALICIOUS_INSTALL_HOOK: package manager running suspicious package in $clean_name")
      FOUND=1
    fi
  done < <(sudo find "$MNT_DIR" -type f -name "*.install" 2>/dev/null || true)
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