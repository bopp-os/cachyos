#!/bin/bash
# Promote a daily deck image to the stable tag of one architecture.
#
# The scheduled builds push cachyos-deck as <arch>-daily and <arch>-YYYYMMDD only. This picks the newest dated build
# from the last WINDOW_DAYS days that is signed by us and has no critical vulnerability with a fix available (the same
# gate the build uses, against today's vulnerability database), and points the stable tag <arch> at its digest (plus
# "latest" for v3). A registry-to-registry copy keeps the digest, so the cosign signature and SBOM stay valid.
#
# It never goes backwards on its own: only builds newer than the window start are considered, and when none is clean it
# promotes nothing and opens (or comments on) an issue.
#
# Usage: promote-deck.sh <arch>            (arch: v3 | v4 | znver4)
# Env:   IMAGE_REGISTRY   registry path (ghcr.io/bopp-os); the image is $IMAGE_REGISTRY/cachyos-deck
#        GITHUB_TOKEN, ACTOR   registry credentials; GH_TOKEN is used for the issue
#        SYFT_IMAGE, GRYPE_IMAGE   pinned, already ClamAV-scanned tool images (run with --pull=never)
#        WINDOW_DAYS      how old a build may be (default 7)
#        EXPLICIT_TAG     promote this dated tag instead of searching (still verified and scanned)
#        DRY_RUN=true     report only, change nothing
#        HOST_PKG_CACHE_DIR   where the grype database is kept between runs
# Run from the repo root (reads cosign.pub, .grype.yaml, .syft.yaml).
set -euo pipefail

ARCH=${1:?usage: promote-deck.sh <v3|v4|znver4>}
case "$ARCH" in v3 | v4 | znver4) ;; *) echo "::error::Unknown arch $ARCH"; exit 2 ;; esac
: "${IMAGE_REGISTRY:?}" "${GITHUB_TOKEN:?}" "${ACTOR:?}" "${SYFT_IMAGE:?}" "${GRYPE_IMAGE:?}"
WINDOW_DAYS=${WINDOW_DAYS:-7}
EXPLICIT_TAG=${EXPLICIT_TAG:-}
DRY_RUN=${DRY_RUN:-false}
HOST_PKG_CACHE_DIR=${HOST_PKG_CACHE_DIR:-/opt/boppos-pkg-cache}
REPO="${IMAGE_REGISTRY,,}/cachyos-deck"
CREDS="${ACTOR}:${GITHUB_TOKEN}"
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

note() { echo "$*"; printf '%s\n' "$*" >> "$SUMMARY"; }

digest_of() { skopeo inspect --no-tags --creds "$CREDS" --format '{{.Digest}}' "docker://$REPO:$1" 2>/dev/null; }

# Opens an issue, or comments on the open one, so a week without a clean build is not silent
report_issue() {
  [ -n "${GH_TOKEN:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] || { echo "::warning::No GH_TOKEN, not opening an issue"; return 0; }
  local api="https://api.github.com/repos/$GITHUB_REPOSITORY" label="deck-promote-$ARCH"
  local run_url="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}"
  local body existing
  body="Nothing was promoted to \`cachyos-deck:$ARCH\` ([run]($run_url)).

$1

The stable tag still points at: \`${CURRENT:-none}\`."
  gh_api() { local m=$1 p=$2; shift 2
    curl -fsS -X "$m" -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" "$api$p" "$@"; }
  existing=$(gh_api GET "/issues?state=open&labels=$label&per_page=1" | jq -r '.[0].number // empty') || existing=
  if [ -n "$existing" ]; then
    jq -n --arg b "$body" '{body: $b}' | gh_api POST "/issues/$existing/comments" --data @- > /dev/null || true
    echo "Commented on issue #$existing"
  else
    jq -n --arg t "Deck $ARCH: no clean build to promote" --arg b "$body" --arg l "$label" \
      '{title: $t, body: $b, labels: [$l]}' | gh_api POST "/issues" --data @- > /dev/null \
      || echo "::warning::Could not open an issue"
  fi
}

# Verify our signature on the digest. Signed with a key (no transparency log), like containers/policy.json expects.
verify_signature() {
  cosign verify --key cosign.pub --insecure-ignore-tlog=true "$REPO@$1" > "$WORK/cosign.txt" 2>&1 || { cat "$WORK/cosign.txt"; return 1; }
}

# Scan the image with the build's own SBOM + grype gate, against the current vulnerability database.
# Prints the findings to $WORK/findings.txt; returns 0 only when the scan ran and found nothing critical with a fix.
scan_clean() {
  local tag=$2 ref="$REPO@$1"
  podman pull -q "docker://$ref" > /dev/null || { echo "could not pull $ref" > "$WORK/findings.txt"; return 1; }
  SYFT_IMAGE="$SYFT_IMAGE" podman unshare bash scripts/syft-sbom.sh "$ref" "cachyos-deck" "$tag" "$WORK/sbom.json" \
    || { echo "SBOM generation failed" > "$WORK/findings.txt"; return 1; }
  local db="$HOST_PKG_CACHE_DIR/.grype-db"
  mkdir -p "$db"
  if ! podman run --rm --pull=never --network=host --security-opt label=disable \
      -v "$WORK/sbom.json":/sbom.json:ro -v "$PWD/.grype.yaml":/config/.grype.yaml:ro -v "$db":/grype-db \
      -e GRYPE_DB_CACHE_DIR=/grype-db -e GRYPE_CHECK_FOR_APP_UPDATE=false \
      "$GRYPE_IMAGE" sbom:/sbom.json --config /config/.grype.yaml -o json > "$WORK/grype.json"; then
    echo "grype could not scan the image" > "$WORK/findings.txt"; return 1
  fi
  jq -r '.matches[]? | select(.vulnerability.severity == "Critical")
    | "\(.vulnerability.id) in \(.artifact.name) \(.artifact.version) (fixed in \(.vulnerability.fix.versions | join(", ")))"' \
    "$WORK/grype.json" > "$WORK/findings.txt"
  [ ! -s "$WORK/findings.txt" ]
}

promote() {
  local digest=$1 dest
  for dest in "$ARCH" $([ "$ARCH" = v3 ] && echo latest); do
    skopeo copy --preserve-digests --all --src-creds "$CREDS" --dest-creds "$CREDS" \
      "docker://$REPO@$digest" "docker://$REPO:$dest"
    note "- \`$REPO:$dest\` now points at \`$digest\`"
  done
}

CURRENT=$(digest_of "$ARCH" || true)
note "### Deck $ARCH"
note "- Stable now: \`${CURRENT:-none}\`"

if [ -n "$EXPLICIT_TAG" ]; then
  [[ "$EXPLICIT_TAG" =~ ^${ARCH}-[0-9]{8}$ ]] || { echo "::error::tag must look like ${ARCH}-YYYYMMDD"; exit 2; }
  CANDIDATES=$EXPLICIT_TAG
else
  CUTOFF=$(date -u -d "$WINDOW_DAYS days ago" +%Y%m%d)
  CANDIDATES=$(skopeo list-tags --creds "$CREDS" "docker://$REPO" | jq -r '.Tags[]' \
    | grep -E "^${ARCH}-[0-9]{8}$" | sort -r | awk -F- -v c="$CUTOFF" '$2 >= c')
fi

if [ -z "$CANDIDATES" ]; then
  note "- No ${ARCH}-YYYYMMDD build from the last $WINDOW_DAYS days."
  report_issue "No build of the last $WINDOW_DAYS days exists. Check the scheduled builds."
  exit 1
fi

REJECTED=
for tag in $CANDIDATES; do
  digest=$(digest_of "$tag") || { note "- $tag: could not read digest, skipped"; continue; }
  if [ "$digest" = "$CURRENT" ]; then
    note "- $tag is already stable; nothing newer is clean, keeping it."
    [ -z "$REJECTED" ] || report_issue "Newer builds were rejected:
$REJECTED"
    exit 0
  fi
  if ! verify_signature "$digest"; then
    note "- $tag: signature check failed, skipped"; REJECTED+="- \`$tag\`: signature check failed"$'\n'; continue
  fi
  clean=false
  if scan_clean "$digest" "$tag"; then clean=true; fi
  # The pulled image is several GB; never keep it
  podman rmi -f "$REPO@$digest" > /dev/null 2>&1 || true
  if [ "$clean" = true ]; then
    note "- $tag: signed, no critical vulnerability with a fix"
    if [ "$DRY_RUN" = true ]; then note "- Dry run: would promote \`$digest\`"; exit 0; fi
    promote "$digest"
    exit 0
  fi
  findings=$(head -20 "$WORK/findings.txt")
  note "- $tag: rejected
\`\`\`
$findings
\`\`\`"
  REJECTED+="- \`$tag\`:"$'\n'"\`\`\`"$'\n'"$findings"$'\n'"\`\`\`"$'\n'
done

note "- No candidate passed. Stable stays where it is."
report_issue "Every build of the last $WINDOW_DAYS days was rejected:
$REJECTED"
exit 1
