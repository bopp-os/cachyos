#!/bin/bash
set -euo pipefail

CACHE_DIR="${1:-/usr/lib/sysimage/cache/pacman/pkg}"

echo "::group::Pre-Build Package Cache Security Scan"
echo "Scanning package archives in $CACHE_DIR..."

if [ ! -d "$CACHE_DIR" ]; then
  echo "Package cache directory $CACHE_DIR does not exist. Skipping pre-scan."
  echo "::endgroup::"
  exit 0
fi

FOUND=0
FINDINGS=()

# Find all package archives in cache
PKG_FILES=$(find "$CACHE_DIR" -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) 2>/dev/null || true)
PKG_COUNT=$(echo "$PKG_FILES" | grep -c "\.pkg\.tar" || true)

echo "Found $PKG_COUNT package archives to inspect..."

if [ "$PKG_COUNT" -gt 0 ]; then
  TAR_CMD="tar"
  if command -v bsdtar >/dev/null 2>&1; then
    TAR_CMD="bsdtar"
  fi

  while IFS= read -r pkg_file; do
    [[ -z "$pkg_file" ]] && continue
    pkg_name=$(basename "$pkg_file")

    # Extract .INSTALL scriptlet if present in package archive
    INSTALL_CONTENT=""
    if [ "$TAR_CMD" = "bsdtar" ]; then
      INSTALL_CONTENT=$(bsdtar -O -xf "$pkg_file" .INSTALL 2>/dev/null || true)
    else
      INSTALL_CONTENT=$(tar -xOf "$pkg_file" .INSTALL 2>/dev/null || true)
    fi

    if [[ -n "$INSTALL_CONTENT" ]]; then
      # 1. Obfuscation & Dynamic Evaluation
      if echo "$INSTALL_CONTENT" | grep -qE '(base64\s+(-d|--decode)|eval\s*\$|openssl\s+enc|xxd\s+-r|\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic-lockfile)'; then
        FINDINGS+=("OBFUSCATED_SCRIPTLET in package archive: $pkg_name")
        FOUND=1
      fi

      # 2. Suspicious Network Egress / Webhooks
      if echo "$INSTALL_CONTENT" | grep -qE '(curl|wget|fetch|ncat|nc\s|/dev/tcp/|discord\.com/api/webhooks|api\.telegram\.org)'; then
        FINDINGS+=("NETWORK_EGRESS_CALL in scriptlet: $pkg_name")
        FOUND=1
      fi

      # 3. Sensitive Path / Credential Access
      if echo "$INSTALL_CONTENT" | grep -qE '(/etc/shadow|\.ssh/|\.aws/|\.config/(BraveSoftware|google-chrome|chromium))'; then
        FINDINGS+=("CREDENTIAL_ACCESS_TARGET in scriptlet: $pkg_name")
        FOUND=1
      fi
    fi
  done <<< "$PKG_FILES"
fi

if [[ $FOUND -eq 1 ]]; then
  echo "::error::🚨 COMPROMISED PACKAGE ARCHIVE DETECTED IN CACHE! 🚨"
  echo "The following suspicious indicators were found in pre-build package cache:"
  for f in "${FINDINGS[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "✅ Package cache pre-scan clean ($PKG_COUNT packages verified)."
echo "::endgroup::"
