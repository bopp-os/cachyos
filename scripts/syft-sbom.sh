#!/bin/bash
# Generate the SBOM of a built image with Syft.
#
# Usage (inside the rootless user namespace, because mounting an image needs it):
#   podman unshare bash scripts/syft-sbom.sh <image-ref> <source-name> <source-version> <output-file>
#
# Needs SYFT_IMAGE (the pinned, ClamAV-scanned syft image) in the environment, and runs from the repo root
# (it reads .syft.yaml from there).
set -euo pipefail

IMAGE_REF=${1:?usage: syft-sbom.sh <image-ref> <source-name> <source-version> <output-file>}
SOURCE_NAME=${2:?}
SOURCE_VERSION=${3:?}
OUTPUT=${4:?}
: "${SYFT_IMAGE:?SYFT_IMAGE must be set}"

MNT_DIR=$(podman image mount "$IMAGE_REF")
# The bind mount below lives in this user namespace's mount namespace and goes away with it
trap 'podman image unmount "$IMAGE_REF" >/dev/null 2>&1 || true' EXIT

# Mirror booted system: bind-mount /usr/lib/opt to /var/opt so /opt has its files populated
if [ -d "$MNT_DIR/usr/lib/opt" ] && [ -d "$MNT_DIR/var/opt" ]; then
  mount --bind "$MNT_DIR/usr/lib/opt" "$MNT_DIR/var/opt"
fi

podman run --rm --pull=never --network=none --security-opt label=disable \
  -v "$MNT_DIR":/rootfs:ro -v "$PWD/.syft.yaml":/config/.syft.yaml:ro -e SYFT_CHECK_FOR_APP_UPDATE=false \
  "$SYFT_IMAGE" dir:/rootfs --config /config/.syft.yaml --source-name "$SOURCE_NAME" --source-version "$SOURCE_VERSION" \
  --override-default-catalogers alpm-db-cataloger -o json > "$OUTPUT"
