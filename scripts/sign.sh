#!/bin/bash
set -euo pipefail

# This script is called by the Justfile to handle image signing.
# It's moved to a separate script to avoid complex shell escaping issues within the Justfile.

# --- Arguments from Justfile ---
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <full_image_name> <architecture>" >&2
    exit 1
fi
FULL_IMAGE="$1"
ARCH="$2"

# --- Logic ---
echo "Signing ${FULL_IMAGE}:${ARCH}..."

# Determine the signing key argument
if [ -n "${COSIGN_PRIVATE_KEY-}" ]; then
    KEY_ARG="--key env://COSIGN_PRIVATE_KEY"
    echo "Using COSIGN_PRIVATE_KEY from environment."
elif [ -f "cosign.key" ]; then
    KEY_ARG="--key cosign.key"
    echo "Using local cosign.key file."
else
    echo "Error: COSIGN_PRIVATE_KEY environment variable is not set and cosign.key is missing." >&2
    exit 1
fi

# Fetch the exact remote digest directly from the registry to account for GHCR mutations
echo "Fetching remote digest from registry for ${FULL_IMAGE}:${ARCH}..."
DIGEST=$(sudo skopeo inspect --authfile=/etc/containers/auth.json --format '{{.Digest}}' "docker://${FULL_IMAGE}:${ARCH}")
if [ -z "$DIGEST" ]; then
    echo "Error: Failed to fetch digest for ${FULL_IMAGE}:${ARCH} from registry." >&2
    exit 1
fi

echo "Signing image with digest: $DIGEST"

# Execute the cosign command with sudo to handle registry authentication.
# `sudo` allows cosign to use the root-owned credentials in /etc/containers/auth.json.
# `sudo -E` is used to preserve the COSIGN_PRIVATE_KEY environment variable if it is set.
# We also explicitly set REGISTRY_AUTH_FILE to ensure cosign finds the correct credentials,
# mirroring the --authfile flag used in the Justfile's push recipe.
sudo -E REGISTRY_AUTH_FILE=/etc/containers/auth.json cosign sign -y --new-bundle-format=false --use-signing-config=false $KEY_ARG "${FULL_IMAGE}:${ARCH}@${DIGEST}" < /dev/null