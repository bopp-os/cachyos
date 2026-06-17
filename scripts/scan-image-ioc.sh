#!/bin/bash
set -euo pipefail
IMAGE_REF=$1
echo "::group::Post-build Image IOC Scan for $IMAGE_REF"
echo "Scanning image filesystem for known IOCs..."
CONTAINER_ID=$(sudo podman create "$IMAGE_REF")
trap "sudo podman rm $CONTAINER_ID >/dev/null 2>&1" EXIT

FOUND=0
FINDINGS=()

# Export filesystem once and work from the tarball
IMAGE_TAR=$(mktemp)
trap "sudo podman rm $CONTAINER_ID >/dev/null 2>&1; rm -f $IMAGE_TAR" EXIT
sudo podman export "$CONTAINER_ID" > "$IMAGE_TAR"

# --- Wave 1: Path-based IOCs (atomic-lockfile / js-digest) ---
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
  result=$(tar -t -f "$IMAGE_TAR" 2>/dev/null | grep -E "$ioc" || true)
  if [[ -n "$result" ]]; then
    FINDINGS+=("PATH: $result")
    FOUND=1
  fi
done

# --- Wave 1: ELF payload hashes ---
# Extract all files and check SHA256 against known payload hashes
KNOWN_HASHES=(
  "6144d433f8a0316869877b5f834c801251bbb936e5f1577c5680878c7443c98b"  # deps (atomic-lockfile)
  "7883bda1ff15425f2dbe622c45a3ae105ddfa6175009bbf0b0cad9bf5c79b316"  # deps (js-digest)
  "47893d9badc38c54b71321263ce8178c1abb10396e0aadf9793e61ec8829e204"  # cryptominer variant
)

# Check for the exact payload size (3,040,376 bytes) as a fast pre-filter
SUSPICIOUS_FILES=$(tar -tv -f "$IMAGE_TAR" 2>/dev/null | awk '$3 == 3040376 {print $NF}' || true)
if [[ -n "$SUSPICIOUS_FILES" ]]; then
  FINDINGS+=("SUSPICIOUS_SIZE(3040376): $SUSPICIOUS_FILES")
  FOUND=1
fi

# --- Wave 2: Obfuscated install hook patterns ---
# Second wave hides commands via hex escapes, mixed quoting, and string splitting
# Extract and scan .install files and PKGBUILDs
INSTALL_CONTENT=$(tar -xOf "$IMAGE_TAR" --wildcards '*.install' 2>/dev/null || true)
if [[ -n "$INSTALL_CONTENT" ]]; then
  # Hex-escaped 'cd' and 'bun' as seen in htbrowser-bin sample
  if echo "$INSTALL_CONTENT" | grep -qE '\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic'; then
    FINDINGS+=("OBFUSCATED_INSTALL_HOOK: hex escapes or known package names in .install file")
    FOUND=1
  fi
  # Any install hook invoking bun, npm, pnpm, yarn with suspicious packages
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
  result=$(tar -t -f "$IMAGE_TAR" 2>/dev/null | grep -F "$ioc" || true)
  if [[ -n "$result" ]]; then
    FINDINGS+=("EBPF_ROOTKIT: $result")
    FOUND=1
  fi
done

# --- Persistence artifacts ---
PERSISTENCE_IOCS=(
  "usr/bin/monero-wallet-gui"             # cryptominer staging target
  "etc/systemd/system/.*Restart=always"  # suspicious systemd unit (checked below)
)

# Check for unexpected executables under /var/lib/ (malware persistence path)
VAR_LIB_EXECS=$(tar -tv -f "$IMAGE_TAR" 2>/dev/null | \
  awk '/^-..x/{print $NF}' | grep '^var/lib/' | \
  grep -vE '(dpkg|apt|systemd|dbus|\.list|\.log)' || true)
if [[ -n "$VAR_LIB_EXECS" ]]; then
  FINDINGS+=("SUSPICIOUS_EXECUTABLE_IN_VAR_LIB: $VAR_LIB_EXECS")
  FOUND=1
fi

# --- Suspicious dependency additions (bun as a PKGBUILD depends) ---
# bun has no business being a dependency of most packages
BUN_DEP=$(tar -xOf "$IMAGE_TAR" --wildcards '*/PKGBUILD' 2>/dev/null | \
  grep -E "depends\s*=.*['\"]bun['\"]" || true)
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
  echo "Failing the build to prevent pushing malware."
  exit 1
fi

echo "✅ No known IOCs found in the image."
echo "::endgroup::"