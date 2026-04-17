# Configuration
registry := "ghcr.io"
user := "ripps818"

# Default action
default:
    @just --list

# Build the prerequisite AUR builder image.
build-aur arch='v3':
    @echo "Building AUR builder for architecture {{arch}}..."
    podman build \
        --network=host \
        --build-arg TARGET_CPU_MARCH={{arch}} \
        --build-arg BASE_IMAGE_TAG=$(if [ "{{arch}}" = "znver4" ]; then echo "v4"; else echo "{{arch}}"; fi) \
        -f Containerfile.aur \
        -t "localhost/aur-builder:{{arch}}" \
        .

# Build a specific flavor of the container image.
# Accepts an optional architecture (v3, v4, znver4) and flavor (base, plasma, gnome, niri).
build arch='v3' flavor='base':
    @echo "Building cachyos-boppos-{{flavor}}:{{arch}}..."
    @if [ "{{flavor}}" = "base" ]; then \
        if ! podman image exists "localhost/aur-builder:{{arch}}"; then \
            echo "⚠️ AUR builder image 'localhost/aur-builder:{{arch}}' not found locally. Building it first..."; \
            just build-aur {{arch}}; \
        fi; \
        podman build \
            --network=host \
            --build-arg TARGET_CPU_MARCH={{arch}} \
            --build-arg BASE_IMAGE_TAG=$(if [ "{{arch}}" = "znver4" ]; then echo "v4"; else echo "{{arch}}"; fi) \
            -f Containerfile.base \
            -t "{{registry}}/{{user}}/cachyos-boppos-base:{{arch}}" \
            .; \
    else \
        podman build \
            --network=host \
            --build-arg BASE_IMAGE_TAG={{arch}} \
            -f Containerfile.{{flavor}} \
            -t "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}:{{arch}}" \
            .; \
    fi

# Push the built image(s) to the container registry.
push arch='v3' flavor='base': (rechunk arch flavor)
    @echo "Pushing cachyos-boppos-{{flavor}}:{{arch}}..."
    set -euo pipefail
    podman push \
        --digestfile=/tmp/podman_push_digest_{{arch}}.txt \
        --compression-format=zstd \
        "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}:{{arch}}"
    @echo "Performing safety push to ensure GHCR metadata syncs..."
    podman push \
        --digestfile=/tmp/podman_push_digest_{{arch}}.txt \
        --compression-format=zstd \
        "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}:{{arch}}"

# Rechunk the built image(s) to optimize layers.
rechunk arch='v3' flavor='base':
    @if [ "{{flavor}}" = "base" ]; then \
        echo "Rechunking cachyos-boppos-base:{{arch}}..."; \
        podman run --rm --mount=type=image,source={{registry}}/{{user}}/cachyos-boppos-base:{{arch}},target=/chunkah \
            -e CHUNKAH_CONFIG_STR="$$(podman inspect {{registry}}/{{user}}/cachyos-boppos-base:{{arch}})" \
            quay.io/coreos/chunkah build --compressed --compression-level 2 --label containers.bootc=1 --max-layers 256 --prune /var/cache/ --prune /var/log/ --prune /tmp/ --prune /var/tmp/ | podman load > /tmp/podman_load_output.txt; \
        IMAGE_ID=$$(cat /tmp/podman_load_output.txt | grep "Loaded image" | awk '{print $$3}'); \
        podman tag "$$IMAGE_ID" "{{registry}}/{{user}}/cachyos-boppos-base:{{arch}}"; \
    else \
        echo "Skipping rechunk for DE overlay {{flavor}}..."; \
    fi

# Sign the published image using cosign. Defaults to cosign.key in the current directory unless COSIGN_PRIVATE_KEY is exported.
sign arch='v3' flavor='base':
    @# The signing logic is complex and has shell escaping issues within Just.
    @# Moving it to a dedicated script makes it more robust and maintainable.
    @./scripts/sign.sh "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}" "{{arch}}"

# Verifies the signatures of all published images for a given architecture
verify arch='v3':
    #!/usr/bin/env bash
    set -euo pipefail
    REGISTRY="{{registry}}/{{user}}"
    FLAVORS=("base" "plasma" "gnome" "niri")
    
    if [ ! -f "cosign.pub" ]; then
        echo "Error: cosign.pub not found in the current directory."
        exit 1
    fi
    
    echo "Verifying signatures for architecture: {{arch}}"
    for FLAVOR in "${FLAVORS[@]}"; do
        echo -e "\n==> Verifying ${REGISTRY}/cachyos-boppos-${FLAVOR}:{{arch}}..."
        cosign verify --key cosign.pub "${REGISTRY}/cachyos-boppos-${FLAVOR}:{{arch}}"
    done
    echo -e "\nAll images for {{arch}} verified successfully!"

switch tag='v3' flavor='plasma':
    @echo "Transferring rootless image to root storage..."
    podman save "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}:{{tag}}" | sudo podman load
    @echo "Switching system to cachyos-boppos-{{flavor}}:{{tag}}..."
    sudo bootc switch \
        --transport containers-storage \
        "{{registry}}/{{user}}/cachyos-boppos-{{flavor}}:{{tag}}"

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
