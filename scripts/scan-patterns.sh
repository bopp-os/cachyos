#!/bin/bash
# shellcheck disable=SC2034 # variables and FINDINGS/FOUND are used by the sourcing scripts
# Shared heuristics for scan-pkg-cache.sh and scan-image-ioc.sh (sourced, not executed).
# Checked against every scriptlet, ALPM hook, ALPM script, systemd unit and profile.d script
# in a published image without false positives; rerun that check before widening them.

# Temp/volatile directories that legitimate system code never executes from
TEMP_DIRS='/(tmp|var/tmp|dev/shm)/'
QUOTE="[\"']?"

PAT_OBFUSCATION='(base64\s+(-d|--decode)|eval\s+(\$|`)|openssl\s+enc|xxd\s+-r|\\x63|\\141\\x6e|nextfile|lockfile|js-digest|atomic-lockfile)'

PAT_NETWORK="((curl|wget|fetch)\s+.*(\||>|\\\$\()|ncat\s|nc\s+-e|/dev/tcp/|discord\.com/api/webhooks|api\.telegram\.org"
# Download-to-temp and make-temp-executable, the two halves of a dropper
PAT_NETWORK+="|(curl|wget)\s[^|;&]*(-o|-O|--output|--output-document)[= ]*${QUOTE}${TEMP_DIRS}"
PAT_NETWORK+="|chmod\s+(\+x|[0-7]{3,4})\s+${QUOTE}${TEMP_DIRS})"

PAT_CREDENTIAL='(/etc/shadow|\.ssh/id_|\.aws/credentials|\.config/(BraveSoftware|google-chrome|chromium)/.*Default)'

# Exec*= lines in systemd units, ALPM hooks and autostart entries that run from a temp dir,
# fetch from the network, decode a payload, or open a raw TCP socket
PAT_EXEC_LINE="^\s*Exec[A-Za-z]*\s*=\s*[-@:+!]*\s*(${TEMP_DIRS}|.*((curl|wget)\s|base64\s+(-d|--decode)|/dev/tcp/|(sh|bash)\s+-c\s+.*https?://))"

# Known artifacts from past supply-chain campaigns
PAT_IOC_PATHS='atomic-lockfile|js-digest|lockfile-js|nextfile-js|src/hooks/deps|node_modules/\.bun|_cacache/.*atomic-lockfile|bun/install/cache/.*js-digest|usr/bin/monero-wallet-gui|sys/fs/bpf/hidden_|(^|/)etc/ld\.so\.preload$'

# check_script <label> <content>: run the shell heuristics on a script body, recording any
# hits in the caller's FINDINGS array and setting FOUND=1. Comment lines are ignored.
check_script() {
  local label=$1 content
  content=$(grep -vE '^\s*#' <<< "$2" || true)
  if grep -qE "$PAT_OBFUSCATION" <<< "$content"; then
    FINDINGS+=("OBFUSCATION in $label")
    FOUND=1
  fi
  if grep -qE "$PAT_NETWORK" <<< "$content"; then
    FINDINGS+=("NETWORK_EGRESS in $label")
    FOUND=1
  fi
  if grep -qE "$PAT_CREDENTIAL" <<< "$content"; then
    FINDINGS+=("CREDENTIAL_ACCESS in $label")
    FOUND=1
  fi
}

# check_exec_lines <label> <content>: flag suspicious Exec*= lines (units, hooks, autostart)
check_exec_lines() {
  local label=$1 hits
  hits=$(grep -E "$PAT_EXEC_LINE" <<< "$2" || true)
  if [[ -n "$hits" ]]; then
    FINDINGS+=("SUSPICIOUS_EXEC in $label: $(head -n 1 <<< "$hits" | sed 's/^\s*//')")
    FOUND=1
  fi
}
