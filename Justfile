# Configuration
registry := "ghcr.io"
user := "ripps818"
image_name := "cachyos-boppos-bootc"
full_image := registry + "/" + user + "/" + image_name

# Default action
default:
    @just --list

# Build the container image.
# Accepts an optional architecture (v3, v4, znver4).
build arch='v3':
    @echo "Building {{full_image}}:{{arch}} for TARGET_CPU_MARCH={{arch}}..."
    sudo podman build \
        --network=host \
        --build-arg TARGET_CPU_MARCH={{arch}} \
        --build-arg BASE_IMAGE_TAG=$(if [ "{{arch}}" = "znver4" ]; then echo "v4"; else echo "{{arch}}"; fi) \
        -t "{{full_image}}:{{arch}}" \
        .

# Rechunk the built image(s) to optimize layers.
rechunk arch='v3':
    @echo "Rechunking {{full_image}}:{{arch}}..."
    sudo podman run --rm --mount=type=image,source={{full_image}}:{{arch}},target=/chunkah \
        -e CHUNKAH_CONFIG_STR="$(sudo podman inspect {{full_image}}:{{arch}})" \
        quay.io/jlebon/chunkah build --label containers.bootc=1 --max-layers 256 | sudo podman load > /tmp/podman_load_output.txt
    IMAGE_ID=$(cat /tmp/podman_load_output.txt | grep "Loaded image" | awk '{print $3}') && \
    sudo podman tag "$IMAGE_ID" "{{full_image}}:{{arch}}"

# Push the built image(s) to the container registry.
push arch='v3': (rechunk arch)
    @echo "Pushing {{full_image}}:{{arch}}..."
    set -euo pipefail
    sudo podman push \
        --authfile /etc/containers/auth.json \
        --digestfile=/tmp/podman_push_digest_{{arch}}.txt \
        --compression-format=zstd \
        "{{full_image}}:{{arch}}"

# Sign the published image using cosign. Defaults to cosign.key in the current directory unless COSIGN_PRIVATE_KEY is exported.
sign arch='v3':
    @# The signing logic is complex and has shell escaping issues within Just.
    @# Moving it to a dedicated script makes it more robust and maintainable.
    @./scripts/sign.sh "{{full_image}}" "{{arch}}"

switch tag='v3':
    @echo "Switching system to {{full_image}}:{{tag}}..."
    sudo bootc switch \
        --transport containers-storage \
        "{{full_image}}:{{tag}}"

# Manually apply kernel arguments to the currently running system for local testing
apply-local-kargs:
    @echo "Applying kernel arguments locally from files/usr/lib/bootc/kargs.d/..."
    @KARGS=$$(grep -h '^kargs' files/usr/lib/bootc/kargs.d/* 2>/dev/null | grep -o '"[^"]*"' | tr -d '"') || true; \
    if [ -z "$$KARGS" ]; then \
        echo "No kernel arguments found in config files."; \
    else \
        CMD="sudo ostree admin kargs edit-in-place"; \
        while IFS= read -r arg; do \
            if [ -n "$$arg" ]; then \
                CMD="$$CMD --append-if-missing=\"$$arg\""; \
            fi; \
        done <<< "$$KARGS"; \
        eval $$CMD; \
        echo "Kernel arguments updated. Please reboot to apply changes."; \
    fi
