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

# Push the built image(s) to the container registry.
push arch='v3':
    @echo "Pushing {{full_image}}:{{arch}}..."
    sudo podman push "{{full_image}}:{{arch}}"

switch tag='v3':
    @echo "Switching system to {{full_image}}:{{tag}}..."
    sudo bootc switch "{{full_image}}:{{tag}}"
