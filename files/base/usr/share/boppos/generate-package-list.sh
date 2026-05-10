#!/bin/bash
set -euo pipefail

# Allow passing the output file path as an argument, defaulting to /usr/share/boppos/packages.json
OUTPUT_FILE="${1:-/usr/share/boppos/packages.json}"

# Ensure the target directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Generating package list from pacman database..."

# Build a JSON mapping of package names to their source repositories
(
  pacman -Sl | awk '/\[installed\]/ {printf "\"%s\":\"%s\",\n", $2, $1}' || true
  pacman -Qm | awk '{printf "\"%s\":\"aur\",\n", $1}' || true
) | sed '$ s/,$//' | sed '1 i\{' | sed '$ a\}' > /tmp/boppos_repo_map.json

# Use pacman -Q to list all packages and versions (e.g., "package-name 1.0-1")
# Use jq to format this into the required JSON structure.
pacman -Q | jq -R -s --slurpfile rmap /tmp/boppos_repo_map.json '
  $rmap[0] as $repos |
  split("\n") |
  map(select(length > 0)) |
  map(
    split(" ") |
    {
      "name": .[0],
      "versionInfo": .[1],
      "repository": ($repos[.[0]] // "unknown")
    }
  ) |
  {
    "packages": .
  }
' > "$OUTPUT_FILE"

rm -f /tmp/boppos_repo_map.json

echo "Package list generated at $OUTPUT_FILE"