#!/bin/bash
set -euo pipefail

IMAGE_REF=$1

echo "::group::Post-build Image IOC Scan for $IMAGE_REF"

echo "Scanning image filesystem for known IOCs..."

CONTAINER_ID=$(sudo podman create "$IMAGE_REF")
trap "sudo podman rm $CONTAINER_ID >/dev/null 2>&1" EXIT

set +e
BAD_PATHS=$(sudo podman export "$CONTAINER_ID" | tar -t | grep -E "atomic-lockfile|js-digest|lockfile-js|src/hooks/deps|node_modules/\.bun")
GREP_EXIT=$?
set -e

if [ $GREP_EXIT -eq 0 ]; then
  echo "::error::🚨 COMPROMISED IMAGE DETECTED! 🚨"
  echo "The following suspicious paths were found in the built image ($IMAGE_REF):"
  echo "$BAD_PATHS"
  echo "Failing the build to prevent pushing malware."
  exit 1
fi

echo "✅ No known IOCs found in the image."
echo "::endgroup::"
