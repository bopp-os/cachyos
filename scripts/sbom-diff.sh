#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <old-sbom.json> <new-sbom.json>"
    echo "Example: $0 sbom-old.json sbom-new.json"
    exit 1
fi

OLD_SBOM="$1"
NEW_SBOM="$2"

# Extract package name and version info, then sort for the comm tool
jq -r '.packages[] | "\(.name) \(.versionInfo)"' "$OLD_SBOM" | sort > /tmp/old_pkgs.txt
jq -r '.packages[] | "\(.name) \(.versionInfo)"' "$NEW_SBOM" | sort > /tmp/new_pkgs.txt

echo "==================================="
echo " Packages Removed/Downgraded"
echo "==================================="
# comm -23 suppresses lines uniquely found in file 2 (-2) and lines common to both (-3).
# It only prints what is uniquely found in file 1 (old_pkgs.txt).
comm -23 /tmp/old_pkgs.txt /tmp/new_pkgs.txt

echo -e "\n==================================="
echo " Packages Added/Upgraded"
echo "==================================="
# comm -13 suppresses lines uniquely found in file 1 (-1) and lines common to both (-3).
# It only prints what is uniquely found in file 2 (new_pkgs.txt).
comm -13 /tmp/old_pkgs.txt /tmp/new_pkgs.txt

# Cleanup
rm -f /tmp/old_pkgs.txt /tmp/new_pkgs.txt