#!/bin/bash
# Compare the layers two chunkah versions produce for the same image.
#
# Usage: compare-chunkah-layers.sh <image-ref> <new-chunkah-image> <old-chunkah-image>
#
# Both versions rechunk the same local image with the flags used for publishing
# (keep them in sync with the Rechunk steps in the build workflows). The input is
# identical, so every layer digest that differs is a layer users would re-download
# purely because of the chunkah upgrade. The OCI archive is streamed, never stored:
# only small files are kept so the manifest can be read.
set -euo pipefail

IMAGE_REF=$1
NEW_CHUNKAH=$2
OLD_CHUNKAH=$3
PODMAN_OPTS=${PODMAN_OPTS:-}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

CONFIG_STR=$(sudo podman inspect "$IMAGE_REF")

# Print "<digest> <size>" for each layer chunkah builds, in manifest order
list_layers() {
    local chunkah_image=$1 out_dir=$2
    mkdir -p "$out_dir"
    # shellcheck disable=SC2086 # PODMAN_OPTS holds multiple arguments
    sudo podman run $PODMAN_OPTS --rm --network=none \
        --mount=type=image,source="$IMAGE_REF",target=/chunkah \
        -e SOURCE_DATE_EPOCH=0 \
        -e CHUNKAH_CONFIG_STR="$CONFIG_STR" \
        "$chunkah_image" build --label containers.bootc=1 --max-layers 450 \
        --prune /var/cache/ --prune /var/log/ --prune /tmp/ --prune /var/tmp/ \
        | OUT_DIR="$out_dir" tar -x --to-command='
            if [ "$TAR_SIZE" -lt 4194304 ]; then
                cat > "$OUT_DIR/$(basename "$TAR_FILENAME")"
            else
                cat > /dev/null
            fi'
    local manifest
    manifest=$(jq -r '.manifests[0].digest | sub("^sha256:"; "")' "$out_dir/index.json")
    jq -r '.layers[] | "\(.digest) \(.size)"' "$out_dir/$manifest"
}

echo "Rechunking $IMAGE_REF with $OLD_CHUNKAH..."
list_layers "$OLD_CHUNKAH" "$WORK_DIR/old" > "$WORK_DIR/old.txt"
echo "Rechunking $IMAGE_REF with $NEW_CHUNKAH..."
list_layers "$NEW_CHUNKAH" "$WORK_DIR/new" > "$WORK_DIR/new.txt"

awk 'NR == FNR { old[$1] = 1; next } !($1 in old)' "$WORK_DIR/old.txt" "$WORK_DIR/new.txt" > "$WORK_DIR/changed.txt"
total=$(wc -l < "$WORK_DIR/new.txt")
changed=$(wc -l < "$WORK_DIR/changed.txt")
total_size=$(awk '{ s += $2 } END { print s + 0 }' "$WORK_DIR/new.txt" | numfmt --to=iec)
changed_size=$(awk '{ s += $2 } END { print s + 0 }' "$WORK_DIR/changed.txt" | numfmt --to=iec)

report="chunkah \`$OLD_CHUNKAH\` → \`$NEW_CHUNKAH\` on \`$IMAGE_REF\`: **$changed of $total layers change** ($changed_size of $total_size uncompressed)."
echo "$report"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "$report" >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$changed" -gt 0 ]; then
    echo "::warning title=chunkah upgrade changes layers::$changed of $total layers of $IMAGE_REF change ($changed_size uncompressed). Users re-download these once after the upgrade."
else
    echo "::notice title=chunkah upgrade keeps layers::All $total layers of $IMAGE_REF are unchanged."
fi
