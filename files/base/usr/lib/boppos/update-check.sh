#!/usr/bin/env bash
# /usr/lib/boppos/update-check.sh
# Runs as root via boppos-update-monitor.service.
# Checks for OCI image updates via bootc and writes a JSON status file
# to /run/boppos/update-status.json for the user-space tray app to read.
#
# Output schema:
#   {
#     "update_available": bool,
#     "checked_at": "<ISO-8601 timestamp>",
#     "current_image": "<digest or ref>",
#     "staged_image": "<digest or ref> | null",
#     "transport": "registry | oci | ...",
#     "diff": "<text output of bopp-diff, or null>",
#     "error": "<error message, or null>"
#   }

set -euo pipefail

STATUS_DIR="/run/boppos"
STATUS_FILE="${STATUS_DIR}/update-status.json"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Ensure the runtime directory exists (created by systemd RuntimeDirectory=)
mkdir -p "${STATUS_DIR}"

write_status() {
    local update_available="$1"
    local current_image="$2"
    local staged_image="$3"
    local transport="$4"
    local diff_output="$5"
    local error_msg="$6"

    # Escape strings for JSON (handle backslashes, quotes, and newlines)
    json_escape() {
        printf '%s' "$1" \
            | sed 's/\\/\\\\/g; s/"/\\"/g' \
            | awk '{printf "%s\\n", $0}' \
            | sed '$ s/\\n$//'
    }

    local diff_json="null"
    if [[ -n "${diff_output}" ]]; then
        diff_json="\"$(json_escape "${diff_output}")\""
    fi

    local error_json="null"
    if [[ -n "${error_msg}" ]]; then
        error_json="\"$(json_escape "${error_msg}")\""
    fi

    local staged_json="null"
    if [[ -n "${staged_image}" ]]; then
        staged_json="\"${staged_image}\""
    fi

    cat > "${STATUS_FILE}.tmp" <<EOF
{
  "update_available": ${update_available},
  "checked_at": "${TIMESTAMP}",
  "current_image": "${current_image}",
  "staged_image": ${staged_json},
  "transport": "${transport}",
  "diff": ${diff_json},
  "error": ${error_json}
}
EOF
    chmod 0644 "${STATUS_FILE}.tmp"
    # Atomic rename so readers never see a partial file
    mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

# ── Parse bootc status JSON ──────────────────────────────────────────────────
if ! command -v bootc &>/dev/null; then
    write_status "false" "unknown" "" "unknown" "" "bootc not found in PATH"
    exit 0
fi

BOOTC_STATUS_JSON=$(bootc status --format=json 2>&1) || {
    write_status "false" "unknown" "" "unknown" "" "bootc status failed: ${BOOTC_STATUS_JSON}"
    exit 0
}

# Use python (already required by the image) to parse the status JSON
PARSE_RESULT=$(python3 - "${BOOTC_STATUS_JSON}" <<'PYEOF'
import json, sys

try:
    data = json.loads(sys.argv[1])
except json.JSONDecodeError as e:
    print(f"ERROR:parse:{e}")
    sys.exit(0)

spec = data.get("spec", {}) or {}
status = data.get("status", {}) or {}
booted = (status.get("booted") or {})
staged = (status.get("staged") or {})

transport = spec.get("image", {}).get("transport", "registry")

# Current image: prefer imageDigest, fall back to image reference
booted_img = (booted.get("image") or {})
current = booted_img.get("imageDigest") or booted_img.get("image", {}).get("image", "unknown")

# If there is a staged deployment AND its digest differs from booted, an update is available
staged_img = (staged.get("image") or {})
staged_digest = staged_img.get("imageDigest") or staged_img.get("image", {}).get("image", "")

update_available = bool(staged_digest and staged_digest != current)

print(f"UPDATE:{update_available}")
print(f"CURRENT:{current}")
print(f"STAGED:{staged_digest}")
print(f"TRANSPORT:{transport}")
PYEOF
)

UPDATE_AVAILABLE="false"
CURRENT_IMAGE="unknown"
STAGED_IMAGE=""
TRANSPORT="registry"
PARSE_ERROR=""

while IFS= read -r line; do
    case "${line}" in
        ERROR:parse:*)   PARSE_ERROR="${line#ERROR:parse:}" ;;
        UPDATE:True)     UPDATE_AVAILABLE="true" ;;
        UPDATE:False)    UPDATE_AVAILABLE="false" ;;
        CURRENT:*)       CURRENT_IMAGE="${line#CURRENT:}" ;;
        STAGED:*)        STAGED_IMAGE="${line#STAGED:}" ;;
        TRANSPORT:*)     TRANSPORT="${line#TRANSPORT:}" ;;
    esac
done <<< "${PARSE_RESULT}"

# ── If no staged image yet, explicitly check upstream for a new one ───────────
# (bootc status only shows a staged image *after* a prior `bootc upgrade --check`
# has downloaded/staged metadata.  Run the lightweight check now.)
if [[ "${UPDATE_AVAILABLE}" == "false" && -z "${PARSE_ERROR}" ]]; then
    CHECK_OUT=$(bootc upgrade --check 2>&1) || true
    # bootc upgrade --check exits 0 whether or not update is available;
    # look for a line like "Update available:" or "No update available"
    if echo "${CHECK_OUT}" | grep -qi "update available"; then
        UPDATE_AVAILABLE="true"
        # Re-read status to pick up the newly staged digest
        BOOTC_STATUS_JSON=$(bootc status --format=json 2>/dev/null) || true
        STAGED_IMAGE=$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
s=(d.get('status',{}) or {}).get('staged') or {}
i=(s.get('image') or {})
print(i.get('imageDigest') or i.get('image',{}).get('image',''))
" <<< "${BOOTC_STATUS_JSON}" 2>/dev/null || echo "")
    fi
fi

# ── Gather diff output if available ─────────────────────────────────────────
DIFF_OUTPUT=""
if [[ "${UPDATE_AVAILABLE}" == "true" ]] && command -v bopp-diff &>/dev/null; then
    # bopp-diff compares current vs staged package lists; run non-interactively
    DIFF_OUTPUT=$(bopp-diff --staged 2>&1 || true)
fi

write_status \
    "${UPDATE_AVAILABLE}" \
    "${CURRENT_IMAGE}" \
    "${STAGED_IMAGE}" \
    "${TRANSPORT}" \
    "${DIFF_OUTPUT}" \
    "${PARSE_ERROR}"

# ── Signal any running tray instances to re-read the status ──────────────────
# We send SIGUSR1 to processes named "bopp-tray" owned by any logged-in user.
# This avoids the tray needing to poll; it can sleep and wake on signal.
pkill -SIGUSR1 -f bopp-tray 2>/dev/null || true

exit 0
