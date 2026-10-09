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
  echo "::error::Package cache directory $CACHE_DIR does not exist; refusing to report a clean scan."
  exit 1
fi

# shellcheck source=scripts/scan-patterns.sh
source "$(dirname "$(readlink -f "$0")")/scan-patterns.sh"

if ! command -v bsdtar >/dev/null 2>&1; then
  echo "::error::bsdtar (libarchive) is required to inspect package archives."
  exit 1
fi

FOUND=0
FINDINGS=()

# -----------------------------------------------------------
# Cryptographic SHA-256 Bit-Sum Cache
# -----------------------------------------------------------
# Bump SCAN_VERSION whenever the checks change so packages verified under older rules are
# rescanned once instead of being skipped forever
SCAN_VERSION=2
CACHE_FILE="$CACHE_DIR/.pkg_scan_cache.v$SCAN_VERSION"
for old_cache in "$CACHE_DIR/.pkg_scan_cache" "$CACHE_DIR"/.pkg_scan_cache.v[0-9]*; do
  if [ "$old_cache" != "$CACHE_FILE" ]; then rm -f "$old_cache"; fi
done
declare -A SCANNED_CACHE=()

if [ -f "$CACHE_FILE" ]; then
  while IFS=' ' read -r hash name; do
    [[ -n "$name" && -n "$hash" ]] && SCANNED_CACHE["$name"]="$hash"
  done < "$CACHE_FILE"
fi

NEW_VERIFIED=()
SKIPPED_COUNT=0
INSPECTED_COUNT=0

# Prepare YARA threat rules once upfront if YARA is available. The local rules must load and
# pass a self-test; the remote rules are optional and dropped with a warning if they fail.
YARA_RULES_DIR=$(mktemp -d /tmp/yara-rules.XXXXXX)
trap 'rm -rf "$YARA_RULES_DIR"' EXIT
YARA_RULES=()
if command -v yara >/dev/null 2>&1; then
  LOCAL_RULES=""
  for candidate in /tmp/files/security/yara_rules.yar files/security/yara_rules.yar; do
    if [ -f "$candidate" ]; then
      LOCAL_RULES="$candidate"
      break
    fi
  done
  if [ -z "$LOCAL_RULES" ]; then
    echo "::error::YARA is installed but files/security/yara_rules.yar was not found."
    exit 1
  fi
  YARA_RULES+=("$LOCAL_RULES")

  REMOTE_RULES="$YARA_RULES_DIR/remote.yar"
  : > "$YARA_RULES_DIR/empty"
  if curl -fsSL --retry 2 --max-time 30 "https://raw.githubusercontent.com/Neo23x0/signature-base/master/yara/gen_webshells.yar" -o "$REMOTE_RULES" &&
    yara "$REMOTE_RULES" "$YARA_RULES_DIR/empty" >/dev/null 2>&1; then
    YARA_RULES+=("$REMOTE_RULES")
  else
    echo "::warning::Remote YARA rules could not be downloaded or loaded; scanning with local rules only."
  fi

  # Self-test: a known-bad sample must match, otherwise the YARA scan is not working
  SELFTEST_FILE="$YARA_RULES_DIR/selftest.sh"
  echo 'echo cGF5bG9hZA== | base64 -d | sh' > "$SELFTEST_FILE"
  if ! yara "${YARA_RULES[@]}" "$SELFTEST_FILE" 2>&1 | grep -q '^Obfuscated_Base64_Payload '; then
    echo "::error::YARA self-test failed: rules from $LOCAL_RULES did not match a known-bad sample."
    exit 1
  fi
  echo "YARA ready: ${#YARA_RULES[@]} rule file(s) loaded, self-test passed."
else
  echo "::warning::YARA is not installed; scanning scriptlets with grep heuristics only."
fi

# Find all package archives in cache
PKG_FILES=$(find "$CACHE_DIR" -type f \( -name "*.pkg.tar.zst" -o -name "*.pkg.tar.xz" \) 2>/dev/null || true)
PKG_COUNT=$(echo "$PKG_FILES" | grep -c "\.pkg\.tar" || true)

echo "Found $PKG_COUNT package archives to inspect (${#SCANNED_CACHE[@]} bit-sums cached)..."
if [ "$PKG_COUNT" -eq 0 ]; then
  echo "::error::No package archives found in $CACHE_DIR; refusing to report a clean scan."
  exit 1
fi

# yara_check <label> <content>: run the YARA rules over a script body, if YARA is available
yara_check() {
  [ ${#YARA_RULES[@]} -gt 0 ] || return 0
  local target="$YARA_RULES_DIR/target" res
  grep -vE '^\s*#' <<< "$2" > "$target" || true
  if ! res=$(yara "${YARA_RULES[@]}" "$target" 2>&1); then
    echo "::error::YARA failed while scanning $1: $res"
    exit 1
  fi
  if [[ -n "$res" ]]; then
    FINDINGS+=("YARA_SIGNATURE_MATCH (${res%% *}) in $1")
    FOUND=1
  fi
}

EXTRACT_DIR="$YARA_RULES_DIR/extract"
HOOK_PATHS_RE='^\./usr/share/libalpm/(hooks|scripts)/'

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

  # .MTREE sits at the front of every package and lists every file, so reading it with
  # --fast-read tells us what to extract without decompressing the whole archive
  FILE_PATHS=$(bsdtar -qxOf "$pkg_file" .MTREE 2>/dev/null | gzip -dc 2>/dev/null | awk '!/type=dir/ && /^\.\// {print $1}' || true)
  if [[ -z "$FILE_PATHS" ]]; then
    echo "::warning::$pkg_name has no readable .MTREE; listing the full archive instead."
    FILE_PATHS=$(bsdtar -tf "$pkg_file" 2>/dev/null | grep -v '/$' | sed 's|^|./|' || true)
  fi

  # 1. Known IOC paths shipped by the package (checked before anything is installed)
  IOC_HITS=$(grep -E "$PAT_IOC_PATHS" <<< "$FILE_PATHS" || true)
  if [[ -n "$IOC_HITS" ]]; then
    FINDINGS+=("IOC_PATH in $pkg_name: $(tr '\n' ' ' <<< "$IOC_HITS")")
    FOUND=1
  fi

  # 2. .INSTALL scriptlet (runs as root during install)
  HAS_INSTALL=0
  if grep -qx '\./\.INSTALL' <<< "$FILE_PATHS"; then
    HAS_INSTALL=1
    INSTALL_CONTENT=$(bsdtar -qxOf "$pkg_file" .INSTALL 2>/dev/null || true)
    check_script "$pkg_name .INSTALL" "$INSTALL_CONTENT"
    yara_check "$pkg_name .INSTALL" "$INSTALL_CONTENT"
  fi

  # 3. ALPM hooks and the scripts they run (also run as root during every transaction)
  mapfile -t HOOK_FILES < <(grep -E "$HOOK_PATHS_RE" <<< "$FILE_PATHS" | sed 's|^\./||' || true)
  if [ ${#HOOK_FILES[@]} -gt 0 ]; then
    rm -rf "$EXTRACT_DIR" && mkdir -p "$EXTRACT_DIR"
    bsdtar -xf "$pkg_file" -C "$EXTRACT_DIR" "${HOOK_FILES[@]}" 2>/dev/null || true
    for hook_file in "${HOOK_FILES[@]}"; do
      [ -f "$EXTRACT_DIR/$hook_file" ] || continue
      HOOK_CONTENT=$(< "$EXTRACT_DIR/$hook_file")
      if [[ "$hook_file" == *.hook ]]; then
        check_exec_lines "$pkg_name /$hook_file" "$HOOK_CONTENT"
      else
        check_script "$pkg_name /$hook_file" "$HOOK_CONTENT"
        yara_check "$pkg_name /$hook_file" "$HOOK_CONTENT"
      fi
    done
  fi

  if [ "$VERBOSE" -eq 1 ]; then
    echo "  🔍 [$CURRENT_IDX] $pkg_name (.INSTALL: $HAS_INSTALL, ALPM hook files: ${#HOOK_FILES[@]})"
  fi

  # Record verified package hash for persistent caching
  if [[ $FOUND -eq 0 && -n "$PKG_HASH" ]]; then
    NEW_VERIFIED+=("$PKG_HASH $pkg_name")
  fi
done <<< "$PKG_FILES"

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
