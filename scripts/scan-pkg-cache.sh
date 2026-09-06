#!/bin/bash
set -euo pipefail

CACHE_DIR="${1:-/usr/lib/sysimage/cache/pacman/pkg}"
# Resolve canonical path to ensure consistent cache lookups across symlinks
CACHE_DIR=$(readlink -f "$CACHE_DIR" 2>/dev/null || echo "$CACHE_DIR")
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

# -----------------------------------------------------------
# Cryptographic SHA-256 Bit-Sum Cache
# -----------------------------------------------------------
CACHE_FILE="$CACHE_DIR/.pkg_scan_cache"
declare -A SCANNED_CACHE=()

if [ -f "$CACHE_FILE" ]; then
  while IFS=' ' read -r hash name; do
    [[ -n "$name" && -n "$hash" ]] && SCANNED_CACHE["$name"]="$hash"
  done < "$CACHE_FILE"
fi

NEW_VERIFIED=()
SKIPPED_COUNT=0
INSPECTED_COUNT=0

# Prepare YARA threat rules once upfront if YARA is available
YARA_RULES_DIR="/tmp/yara-rules"
YARA_COMPILED=""
if command -v yara >/dev/null 2>&1; then
  if [ ! -d "$YARA_RULES_DIR" ]; then
    mkdir -p "$YARA_RULES_DIR"
    curl -sSL --retry 2 --max-time 10 "https://raw.githubusercontent.com/Neo23x0/signature-base/master/yara/gen_webshells.yar" -o "$YARA_RULES_DIR/remote.yar" 2>/dev/null || true
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
    if command -v yarac >/dev/null 2>&1; then
      yarac "$YARA_RULES_DIR/combined.yar" "$YARA_RULES_DIR/combined.yarc" 2>/dev/null || true
      if [ -f "$YARA_RULES_DIR/combined.yarc" ]; then
        YARA_COMPILED="$YARA_RULES_DIR/combined.yarc"
      fi
    fi
  fi
fi

# Find all package archives in cache
PKG_FILES=$(find "$CACHE_DIR" -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) 2>/dev/null || true)
PKG_COUNT=$(echo "$PKG_FILES" | grep -c "\.pkg\.tar" || true)

echo "Found $PKG_COUNT package archives to inspect (${#SCANNED_CACHE[@]} bit-sums cached)..."

if [ "$PKG_COUNT" -gt 0 ]; then
  TAR_CMD="tar"
  if command -v bsdtar >/dev/null 2>&1; then
    TAR_CMD="bsdtar"
  fi

  CURRENT_IDX=0
  while IFS= read -r pkg_file; do
    [[ -z "$pkg_file" ]] && continue
    pkg_name=$(basename "$pkg_file")

    # Cryptographic SHA-256 bit sum verification
    PKG_HASH=$(sha256sum "$pkg_file" 2>/dev/null | awk '{print $1}')
    if [[ -n "$PKG_HASH" && "${SCANNED_CACHE[$pkg_name]:-}" == "$PKG_HASH" ]]; then
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      continue
    fi

    INSPECTED_COUNT=$((INSPECTED_COUNT + 1))
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
        TMP_SCRIPT_FILE=$(mktemp /tmp/scriptlet.XXXXXX)
        echo "$CLEAN_CONTENT" > "$TMP_SCRIPT_FILE"
        if [ -n "$YARA_COMPILED" ] && [ -f "$YARA_COMPILED" ]; then
          YARA_RES=$(yara -C "$YARA_COMPILED" "$TMP_SCRIPT_FILE" 2>/dev/null || true)
        elif [ -f "$YARA_RULES_DIR/combined.yar" ]; then
          YARA_RES=$(yara "$YARA_RULES_DIR/combined.yar" "$TMP_SCRIPT_FILE" 2>/dev/null || true)
        else
          YARA_RES=""
        fi
        rm -f "$TMP_SCRIPT_FILE"
        if [[ -n "$YARA_RES" ]]; then
          FINDINGS+=("YARA_SIGNATURE_MATCH ($YARA_RES) in scriptlet: $pkg_name")
          FOUND=1
        fi
      fi
    fi

    # Record verified package hash for persistent caching
    if [[ $FOUND -eq 0 && -n "$PKG_HASH" ]]; then
      NEW_VERIFIED+=("$PKG_HASH $pkg_name")
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

# Persist newly verified clean package bit-sums to cache file
if [ ${#NEW_VERIFIED[@]} -gt 0 ] && [ -w "$CACHE_DIR" ]; then
  printf "%s\n" "${NEW_VERIFIED[@]}" >> "$CACHE_FILE"
fi

echo "✅ Package cache scan clean: $PKG_COUNT packages verified ($SKIPPED_COUNT cached bit-sums verified, $INSPECTED_COUNT newly scanned)."
echo "::endgroup::"
