#!/bin/bash
set -euo pipefail
IMAGE_REF=$1
echo "::group::Post-build Image IOC Scan for $IMAGE_REF"
echo "Scanning image filesystem for known IOCs..."
CONTAINER_ID=$(sudo podman create "$IMAGE_REF")
trap "sudo podman rm $CONTAINER_ID >/dev/null 2>&1" EXIT

FOUND=0
FINDINGS=()

# Stream helper — re-exports on each call, avoids writing image to disk
export_stream() {
  sudo podman export "$CONTAINER_ID" 2>/dev/null
}

# Wrapper that safely greps the stream without breaking the pipe
stream_grep() {
  local pattern=$1
  local result
  # set +o pipefail locally so grep exit 1 (no match) doesn't kill the pipe
  result=$(set +o pipefail; export_stream | tar -t 2>/dev/null | grep -E "$pattern" || true)
  echo "$result"
}

stream_extract() {
  local pattern=$1
  set +o pipefail
  export_stream | tar -xO --wildcards "$pattern" 2>/dev/null || true
  set -o pipefail
}

# --- Wave 1: Path-based IOCs ---
PATH_IOCS=(
  "atomic-lockfile"
  "js-digest"
  "lockfile-js"
  "nextfile-js"
  "src/hooks/deps"
  "node_modules/\.bun"
  "\.npm/_cacache/.*atomic-lockfile"
  "\.bun/install/cache/.*js-digest"
)

for ioc in "${PATH_IOCS[@]}"; do
  result=$(stream_grep "$ioc")
  if [[ -n "$result" ]]; then
    FINDINGS+=("PATH: $result")
    FOUND=1
  fi
done

# --- Wave 1: Suspicious file size (deps payload is exactly 3,040,376 bytes) ---
SUSPICIOUS_FILES=$(set +o pipefail; export_stream | tar -tv 2>/dev/null | awk '$3 == 3040376 {print $NF}' || true)
if [[ -n "$SUSPICIOUS_FILES" ]]; then
  FINDINGS+=("SUSPICIOUS_SIZE(3040376): $SUSPICIOUS_FILES")
  FOUND=1
fi

# --- Wave 2: Obfuscated install hooks ---
INSTALL_CONTENT=$(stream_extract '*.install')
if [[ -n "$INSTALL_CONTENT" ]]; then
  if echo "$INSTALL_CONTENT" | grep -qE '\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic'; then
    FINDINGS+=("OBFUSCATED_INSTALL_HOOK: hex escapes or known package names in .install file")
    FOUND=1
  fi
  if echo "$INSTALL_CONTENT" | grep -qE '(bun|npm|pnpm|yarn)\s+(install|add)\s+.*(lockfile|digest|nextfile)'; then
    FINDINGS+=("MALICIOUS_INSTALL_HOOK: package manager installing suspicious package in hook")
    FOUND=1
  fi
fi

# --- eBPF rootkit artifacts ---
BPF_IOCS=(
  "sys/fs/bpf/hidden_pids"
  "sys/fs/bpf/hidden_names"
  "sys/fs/bpf/hidden_inodes"
)
for ioc in "${BPF_IOCS[@]}"; do
  result=$(set +o pipefail; export_stream | tar -t 2>/dev/null | grep -F "$ioc" || true)
  if [[ -n "$result" ]]; then
    FINDINGS+=("EBPF_ROOTKIT: $result")
    FOUND=1
  fi
done

# --- Suspicious executables under /var/lib/ ---
VAR_LIB_EXECS=$(set +o pipefail; export_stream | tar -tv 2>/dev/null | \
  awk '/^-..x/{print $NF}' | grep '^var/lib/' | \
  grep -vE '(dpkg|apt|systemd|dbus|plocate|flatpak|containers|docker|fwupd|waydroid|\.list|\.log)' || true)
if [[ -n "$VAR_LIB_EXECS" ]]; then
  FINDINGS+=("SUSPICIOUS_EXECUTABLE_IN_VAR_LIB: $VAR_LIB_EXECS")
  FOUND=1
fi

# --- bun as a PKGBUILD dependency ---
BUN_DEP=$(stream_extract '*/PKGBUILD' | grep -E "depends\s*=.*['\"]bun['\"]" || true)
if [[ -n "$BUN_DEP" ]]; then
  FINDINGS+=("SUSPICIOUS_DEPENDS_BUN: $BUN_DEP")
  FOUND=1
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