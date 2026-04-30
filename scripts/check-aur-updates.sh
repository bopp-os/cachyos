#!/bin/bash
set -euo pipefail

# Dynamically resolve the project root based on the script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PKGBUILDS_DIR="$PROJECT_ROOT/files/aur/pkgbuilds"

if [ ! -d "$PKGBUILDS_DIR" ]; then
    echo "Error: Directory '$PKGBUILDS_DIR' does not exist." >&2
    exit 1
fi

echo "Checking for upstream updates in $PKGBUILDS_DIR..."
echo "--------------------------------------------------------"

for repo in "$PKGBUILDS_DIR"/*/; do
    # Strip trailing slash and get the base name
    repo="${repo%/}"
    repo_name="$(basename "$repo")"

    if [ ! -d "$repo/.git" ]; then
        continue
    fi

    echo "=> Checking: $repo_name"
    pushd "$repo" > /dev/null

    # Fetch latest changes from the remote without modifying the working tree
    git fetch --quiet --all

    # Compare local HEAD with the tracked upstream branch
    if git rev-parse @{u} > /dev/null 2>&1; then
        NEW_COMMITS=$(git log HEAD..@{u} --oneline)
        if [ -n "$NEW_COMMITS" ]; then
            echo -e "\033[1;33m   [!] New commits available upstream:\033[0m"
            git log HEAD..@{u} --oneline --color=always | sed 's/^/       /'
        else
            echo -e "\033[1;32m   [✓] Up to date.\033[0m"
        fi
    else
        echo -e "\033[1;31m   [?] No tracked upstream branch found.\033[0m"
    fi

    popd > /dev/null
    echo ""
done