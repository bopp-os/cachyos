#!/usr/bin/env bash
# Rechunk an image and report its layers by chunkah component, largest first.
#
# Usage: report-chunkah-layers.sh <image-ref> <chunkah-image>
#
# Used by the PR dry run so a change to component tagging shows how the layers split. Uses the same chunkah flags
# as publishing (keep them in sync with the Rechunk steps in the build workflows). The OCI archive is streamed and
# only its small JSON blobs are kept. Sizes are uncompressed (the dry run does not compress).
set -euo pipefail

IMAGE_REF=$1
CHUNKAH_IMAGE=$2
TOP=${TOP:-25}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# shellcheck disable=SC2016 # tar's child shell expands TAR_SIZE and TAR_FILENAME
podman run --rm --network=none --pull=never \
    --mount=type=image,source="$IMAGE_REF",target=/chunkah \
    -e SOURCE_DATE_EPOCH=0 \
    -e CHUNKAH_CONFIG_STR="$(podman inspect "$IMAGE_REF")" \
    "$CHUNKAH_IMAGE" build --label containers.bootc=1 --max-layers 450 \
    --prune /var/cache/ --prune /var/log/ --prune /tmp/ --prune /var/tmp/ \
    | OUT_DIR="$WORK_DIR" tar -x --to-command='
        if [ "$TAR_SIZE" -lt 4194304 ]; then
            cat > "$OUT_DIR/$(basename "$TAR_FILENAME")"
        else
            cat > /dev/null
        fi'

manifest=$(jq -r '.manifests[0].digest | sub("^sha256:"; "")' "$WORK_DIR/index.json")
config=$(jq -r '.config.digest | sub("^sha256:"; "")' "$WORK_DIR/$manifest")

# "<size>\t<component list>" per layer: history entries without empty_layer line up with the manifest's layers
jq -r --slurpfile cfg "$WORK_DIR/$config" '
    [$cfg[0].history[] | select(.empty_layer | not) | .comment] as $names
    | [.layers | to_entries[] | {size: .value.size, name: ($names[.key] // "?")}]
    | sort_by(-.size)[] | "\(.size)\t\(.name)"' "$WORK_DIR/$manifest" > "$WORK_DIR/layers.tsv"

total=$(wc -l < "$WORK_DIR/layers.tsv")
total_size=$(awk -F'\t' '{ s += $1 } END { print s + 0 }' "$WORK_DIR/layers.tsv" | numfmt --to=iec)

{
    echo "### Layers of \`$IMAGE_REF\`: $total layers, $total_size uncompressed"
    echo
    echo "| Size | Component(s) |"
    echo "|---:|---|"
    head -n "$TOP" "$WORK_DIR/layers.tsv" | while IFS=$'\t' read -r size name; do
        echo "| $(numfmt --to=iec "$size") | ${name:0:200} |"
    done
} | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
