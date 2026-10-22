#!/bin/bash
# Reports out-of-date Chaotic-AUR keys in a GitHub issue: comments on the open issue labelled chaotic-keys, or opens
# one. Needs GH_TOKEN (issues: write) and GITHUB_REPOSITORY; GITHUB_SERVER_URL and GITHUB_RUN_ID link the run.
# Usage: chaotic-keys-issue.sh <details-file>
set -eo pipefail

DETAILS=$(cat "$1")
API="https://api.github.com/repos/$GITHUB_REPOSITORY"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
LABEL="chaotic-keys"

gh_api() {
  local method=$1 path=$2
  shift 2
  curl -fsS -X "$method" -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$API$path" "$@"
}

report="Detected by [${GITHUB_WORKFLOW:-a workflow run}]($RUN_URL):

\`\`\`
$DETAILS
\`\`\`"

existing=$(gh_api GET "/issues?state=open&labels=$LABEL&per_page=1" | jq -r '.[0].number // empty')
if [ -n "$existing" ]; then
  jq -n --arg body "$report" '{body: $body}' | gh_api POST "/issues/$existing/comments" --data @- >/dev/null
  echo "Commented on issue #$existing"
  exit 0
fi

body="The committed Chaotic-AUR keys (\`files/keys/chaotic-*.asc\`) look out of date. They're not updated automatically: review the change before trusting it.

$report

### Updating the keys
1. Fetch each pinned key by full fingerprint (\`CHAOTIC_FPRS\` in \`scripts/setup_pacman_repos.sh\`):
   \`curl -fsS -o chaotic-N.asc \"https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x<fingerprint>\"\`
2. Inspect it: \`gpg --show-keys chaotic-N.asc\` (new subkeys, expiry dates, revocations), and cross-check with
   Chaotic-AUR's announcements before trusting a new subkey.
3. A different primary key means Chaotic-AUR rotated keys: update \`CHAOTIC_FPRS\` only after confirming it out of band.
4. Open a PR replacing \`files/keys/chaotic-*.asc\`; \`scripts/check-chaotic-keys.sh --keyserver\` should then pass.
5. Close this issue once merged."

gh_api POST "/labels" --data "$(jq -n --arg name "$LABEL" '{name: $name, color: "d93f0b", description: "Chaotic-AUR signing keys need review"}')" \
  >/dev/null 2>&1 || true
number=$(jq -n --arg title "Chaotic-AUR keys out of date" --arg body "$body" --arg label "$LABEL" \
  '{title: $title, body: $body, labels: [$label]}' | gh_api POST "/issues" --data @- | jq -r .number)
echo "Opened issue #$number"
