#!/bin/bash
set -euo pipefail

CACHE_DIR="${1:-/usr/lib/sysimage/cache/pacman/pkg}"
VERBOSE=0

for arg in "$@"; do
  if [ "$arg" = "--verbose" ] || [ "$arg" = "-v" ]; then
    VERBOSE=1
  fi
done

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

  CURRENT_IDX=0
  while IFS= read -r pkg_file; do
    [[ -z "$pkg_file" ]] && continue
    pkg_name=$(basename "$pkg_file")
    CURRENT_IDX=$((CURRENT_IDX + 1))

    # Extract .INSTALL scriptlet if present in package archive
    INSTALL_CONTENT=""
    if [ "$TAR_CMD" = "bsdtar" ]; then
      INSTALL_CONTENT=$(bsdtar -O -xf "$pkg_file" .INSTALL 2>/dev/null || true)
    else
      INSTALL_CONTENT=$(tar -xOf "$pkg_file" .INSTALL 2>/dev/null || true)
    fi

    if [ "$VERBOSE" -eq 1 ]; then
      if [ -n "$INSTALL_CONTENT" ]; then
        echo "  🔍 [$CURRENT_IDX/$PKG_COUNT] Inspecting $pkg_name (.INSTALL scriptlet found)..."
      else
        echo "  🔍 [$CURRENT_IDX/$PKG_COUNT] Inspecting $pkg_name (clean binary archive)..."
      fi
    fi

    if [[ -n "$INSTALL_CONTENT" ]]; then
      # Strip comment lines to prevent false positives on documentation or echo URLs
      CLEAN_CONTENT=$(echo "$INSTALL_CONTENT" | grep -vE '^\s*#' || true)

      # 1. Obfuscation & Dynamic Evaluation (detecting active execution)
      if echo "$CLEAN_CONTENT" | grep -qE '(base64\s+(-d|--decode)|eval\s+(\$|`)|openssl\s+enc|xxd\s+-r|\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic-lockfile)'; then
        FINDINGS+=("OBFUSCATED_SCRIPTLET in package archive: $pkg_name")
        FOUND=1
      fi

      # 2. Suspicious Outbound Execution & Webhooks (distinguishing active commands from echo text)
      if echo "$CLEAN_CONTENT" | grep -qE '((curl|wget|fetch)\s+.*(\||>|\$\()|ncat\s|nc\s+-e|/dev/tcp/|discord\.com/api/webhooks|api\.telegram\.org)'; then
        FINDINGS+=("NETWORK_EGRESS_CALL in scriptlet: $pkg_name")
        FOUND=1
      fi

      # 3. Sensitive Path / Credential Access
      if echo "$CLEAN_CONTENT" | grep -qE '(/etc/shadow|\.ssh/id_|\.aws/credentials|\.config/(BraveSoftware|google-chrome|chromium)/.*Default)'; then
        FINDINGS+=("CREDENTIAL_ACCESS_TARGET in scriptlet: $pkg_name")
        FOUND=1
      fi

      # 4. YARA Threat Signature Scan (if YARA is available)
      if command -v yara >/dev/null 2>&1; then
        YARA_RULES_DIR="/tmp/yara-rules"
        if [ ! -d "$YARA_RULES_DIR" ]; then
          mkdir -p "$YARA_RULES_DIR"
          # Quietly fetch remote rules without spilling 404 errors
          curl -sSL --retry 2 --max-time 10 "https://raw.githubusercontent.com/Neo23x0/signature-base/master/yara/gen_webshells.yar" -o "$YARA_RULES_DIR/remote.yar" 2>/dev/null || true
          
          # Combine with local committed YARA rules if present
          if [ -f "/tmp/files/security/yara_rules.yar" ]; then
            cat "/tmp/files/security/yara_rules.yar" >> "$YARA_RULES_DIR/combined.yar"
          elif [ -f "files/security/yara_rules.yar" ]; then
            cat "files/security/yara_rules.yar" >> "$YARA_RULES_DIR/combined.yar"
          fi
          if [ -f "$YARA_RULES_DIR/remote.yar" ]; then
            cat "$YARA_RULES_DIR/remote.yar" >> "$YARA_RULES_DIR/combined.yar" 2>/dev/null || true
          fi
        fi

        if [ -f "$YARA_RULES_DIR/combined.yar" ]; then
          TMP_SCRIPT_FILE=$(mktemp /tmp/scriptlet.XXXXXX)
          echo "$CLEAN_CONTENT" > "$TMP_SCRIPT_FILE"
          YARA_RES=$(yara "$YARA_RULES_DIR/combined.yar" "$TMP_SCRIPT_FILE" 2>/dev/null || true)
          rm -f "$TMP_SCRIPT_FILE"
          if [[ -n "$YARA_RES" ]]; then
            FINDINGS+=("YARA_SIGNATURE_MATCH ($YARA_RES) in scriptlet: $pkg_name")
            FOUND=1
          fi
        fi
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
