#!/bin/bash
set -euo pipefail

# Allow passing the output file path as an argument, defaulting to /usr/share/boppos/packages.json
OUTPUT_FILE="${1:-/usr/share/boppos/packages.json}"

# Ensure the target directory exists
mkdir -p "$(dirname "$OUTPUT_FILE")"

echo "Generating package list from pacman database..."

# Use pacman -Q to list all packages and versions (e.g., "package-name 1.0-1")
# Use jq to format this into the required JSON structure.
# The -R flag reads raw string input, and -s slurps it into an array.
# The logic splits each line into name/version and creates the object.
pacman -Q | jq -R -s '
  split("\n") |
  map(select(length > 0)) |
  map(
    split(" ") |
    {
      "name": .[0],
      "versionInfo": .[1]
    }
  ) |
  {
    "packages": .
  }
' > "$OUTPUT_FILE"

echo "Package list generated at $OUTPUT_FILE"